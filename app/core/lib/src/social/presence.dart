import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub/api.dart';
import '../hub/hub_client.dart';

/// Who else is watching what, and requests to join.
///
/// While [start]ed, posts this device's presence every [interval] (and right
/// away when [setWatching] changes it), and keeps [activity] from the answer.
/// One call does both jobs, so the bubble costs one request per interval.
class Presence extends ChangeNotifier {
  Presence({required HubClient? Function() hub, this.interval = const Duration(seconds: 20)}) : _hub = hub;

  final HubClient? Function() _hub;
  final Duration interval;

  Activity _activity = Activity.empty;
  Activity get activity => _activity;

  /// The Hub has answered at least once.
  bool get loaded => _loaded;
  bool _loaded = false;

  /// The last poll failed (the list may be out of date).
  bool get offline => _offline;
  bool _offline = false;

  NowWatching? _watching;
  NowWatching? get watching => _watching;

  /// Where the player is now, read at each report while something plays.
  PlaybackInfo? Function()? playback;

  /// When false, what plays is sent marked private: friends don't see it,
  /// only the admin's Tracearr does.
  bool get share => _share;
  bool _share = true;
  set share(bool value) {
    if (value == _share) return;
    _share = value;
    unawaited(poke());
  }

  final _accepted = StreamController<JoinRequest>.broadcast();
  final _asked = StreamController<JoinRequest>.broadcast();
  final _declined = StreamController<JoinRequest>.broadcast();
  final Set<String> _seen = {};

  /// Fires once for each of this user's requests the other person accepted,
  /// with the room to join.
  Stream<JoinRequest> get accepted => _accepted.stream;

  /// Fires once for each new request to join this user.
  Stream<JoinRequest> get asked => _asked.stream;

  /// Fires once for each of this user's requests that was declined.
  Stream<JoinRequest> get declined => _declined.stream;

  List<FriendActivity> get friends => _activity.friends;
  int get watchingCount => friends.where((f) => f.watching != null).length;

  /// Requests to join this user, waiting for an answer.
  List<JoinRequest> get incoming => [
    for (final r in _activity.requests)
      if (r.incoming && r.pending) r,
  ];

  /// This user's latest request to [userId], if it's still listed.
  JoinRequest? requestTo(String userId) =>
      _activity.requests.where((r) => !r.incoming && r.person.id == userId).firstOrNull;

  Timer? _timer;
  bool get running => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(poke()));
    unawaited(poke());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// What this device plays now; null when nothing does.
  void setWatching(NowWatching? watching) {
    if (watching == _watching) return;
    _watching = watching;
    if (running) unawaited(poke());
  }

  Future<void>? _inFlight;
  bool _again = false;

  /// Posts presence now. Never throws; [offline] says whether it worked.
  Future<void> poke() async {
    if (_inFlight != null) {
      _again = true;
      return _inFlight;
    }
    final done = _inFlight = _send();
    try {
      await done;
    } finally {
      _inFlight = null;
    }
    if (_again) {
      _again = false;
      await poke();
    }
  }

  Future<void> _send() async {
    final hub = _hub();
    if (hub == null) return;
    try {
      _apply(await hub.presence(_watching?.sent(playback: playback?.call(), private: !_share)));
      _offline = false;
    } on HubException {
      _offline = true;
      notifyListeners();
    }
  }

  /// Asks [userId] to let this user join. Throws [HubException].
  Future<void> ask(String userId) async => _apply(await _require().askToJoin(userId));

  /// Lets the requester in to [room], or declines. Throws [HubException].
  Future<void> answer(JoinRequest request, {required bool accept, String? room}) async =>
      _apply(await _require().answerJoinRequest(request.id, accept: accept, room: room));

  /// Withdraws or clears a request. Throws [HubException].
  Future<void> cancel(JoinRequest request) async => _apply(await _require().cancelJoinRequest(request.id));

  HubClient _require() {
    final hub = _hub();
    if (hub == null) throw const HubException('Sign in first.');
    return hub;
  }

  void _apply(Activity activity) {
    _activity = activity;
    _loaded = true;
    for (final r in activity.requests) {
      final key = '${r.id}:${r.status}';
      if (!_seen.add(key)) continue;
      if (r.incoming && r.pending) _asked.add(r);
      if (!r.incoming && r.accepted && r.room != null) _accepted.add(r);
      if (!r.incoming && r.declined) _declined.add(r);
    }
    notifyListeners();
  }

  /// Forgets everything, such as after signing out.
  void clear() {
    _activity = Activity.empty;
    _loaded = false;
    _seen.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _accepted.close();
    _asked.close();
    _declined.close();
    super.dispose();
  }
}
