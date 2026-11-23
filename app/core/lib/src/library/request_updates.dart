import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../hub/api.dart';
import '../hub/hub_client.dart';
import '../session/hub_session.dart';
import '../settings/app_settings.dart';

/// Which of the user's requests the admin answered since they last looked, and which just reached the library.
///
/// It asks the Hub for requests now and then while signed in ([every]), and also follows every reload the
/// Search page does. Status changes on the user's own requests stay [unseen] until [markSeen] (Search shows
/// them). A request that became Added is announced once through [arrivals]. What was seen and announced is kept
/// in [Settings.seenRequests], so a restart doesn't announce anything again. The first time it runs it only
/// remembers what's there, so nothing old is announced.
class RequestUpdates extends ChangeNotifier {
  RequestUpdates({required this.session, required this.settings, this.every = const Duration(minutes: 5)}) {
    session.addListener(_onSession);
    _onSession();
  }

  final HubSession session;
  final AppSettings settings;
  final Duration every;

  Timer? _timer;
  bool _wasSignedIn = false;
  List<MediaRequest>? _lastSeenList;

  /// Requests of the user's whose status changed since [markSeen].
  Set<String> get unseen => _unseen;
  Set<String> _unseen = const {};
  bool get hasUnseen => _unseen.isNotEmpty;

  final _arrivals = StreamController<MediaRequest>.broadcast();

  /// The user's requests that just became Added, each once.
  Stream<MediaRequest> get arrivals => _arrivals.stream;

  void _onSession() {
    final signedIn = session.status == SessionStatus.signedIn && session.hub != null;
    if (signedIn != _wasSignedIn) {
      _wasSignedIn = signedIn;
      _timer?.cancel();
      _timer = null;
      if (signedIn) {
        _timer = Timer.periodic(every, (_) => unawaited(check()));
        unawaited(check());
      } else {
        _unseen = const {};
        notifyListeners();
      }
    }
    // Follow reloads done elsewhere (the Search page).
    if (signedIn && session.requestsLoaded && !identical(session.requests, _lastSeenList)) {
      _lastSeenList = session.requests;
      _compare(session.requests);
    }
  }

  /// Fetches the requests and compares. Never throws.
  Future<void> check() async {
    if (session.hub == null) return;
    try {
      await session.loadRequests();
    } on HubException {
      // Try again next time.
    }
  }

  /// What was seen and announced, by request id: `{"seen": {id: status}, "told": {id: status}}`.
  (Map<String, String>, Map<String, String>)? _memory() {
    final raw = settings.get(Settings.seenRequests);
    if (raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      Map<String, String> map(Object? v) => {
        for (final e in (v as Map<String, dynamic>? ?? const {}).entries) e.key: '${e.value}',
      };
      return (map(j['seen']), map(j['told']));
    } catch (_) {
      return null;
    }
  }

  Future<void> _remember(Map<String, String> seen, Map<String, String> told) =>
      settings.set(Settings.seenRequests, jsonEncode({'seen': seen, 'told': told}));

  void _compare(List<MediaRequest> all) {
    final mine = [
      for (final r in all)
        if (r.mine) r,
    ];
    final memory = _memory();
    if (memory == null) {
      // First run: everything there now counts as seen.
      final now = {for (final r in mine) r.id: r.status};
      unawaited(_remember(now, now));
      return;
    }
    final (seen, told) = memory;
    var changed = false;
    final unseen = <String>{};
    for (final r in mine) {
      final before = seen[r.id];
      if (before == null) {
        // Asked for on this device (or another one): nothing to tell.
        seen[r.id] = r.status;
        told[r.id] = r.status;
        changed = true;
        continue;
      }
      if (before != r.status) unseen.add(r.id);
      if (r.status == RequestStatus.added && told[r.id] != RequestStatus.added) {
        _arrivals.add(r);
        changed = true;
      }
      if (told[r.id] != r.status) {
        told[r.id] = r.status;
        changed = true;
      }
    }
    // Forget requests that are gone.
    final ids = {for (final r in mine) r.id};
    if (seen.keys.any((id) => !ids.contains(id))) {
      seen.removeWhere((id, _) => !ids.contains(id));
      told.removeWhere((id, _) => !ids.contains(id));
      changed = true;
    }
    if (changed) unawaited(_remember(seen, told));
    if (!setEquals(unseen, _unseen)) {
      _unseen = unseen;
      notifyListeners();
    }
  }

  /// The user looked at their requests: what they see now counts as seen.
  Future<void> markSeen() async {
    final mine = [
      for (final r in session.requests)
        if (r.mine) r,
    ];
    final told = _memory()?.$2 ?? {};
    for (final r in mine) {
      told[r.id] ??= r.status;
    }
    await _remember({for (final r in mine) r.id: r.status}, told);
    if (_unseen.isNotEmpty) {
      _unseen = const {};
      notifyListeners();
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _timer?.cancel();
    _arrivals.close();
    super.dispose();
  }
}
