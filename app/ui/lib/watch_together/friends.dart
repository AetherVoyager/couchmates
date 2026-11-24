import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';

import 'watch_together.dart';

/// Connects [Presence] to the rest of the app: tells the Hub what the player
/// has open, joins the room when someone lets this user in, and creates a
/// room to let others in.
class FriendsLink extends ChangeNotifier {
  FriendsLink({required this.session, required this.settings, required this.watch, required this.messenger}) {
    presence = Presence(hub: () => session.status == SessionStatus.signedIn ? session.hub : null);
    presence.share = settings.get(Settings.shareActivity);
    session.addListener(_onSession);
    settings.addListener(_onSettings);
    watch.addListener(_update);
    _subs.addAll([
      presence.accepted.listen(_onAccepted),
      presence.asked.listen(_onAsked),
      presence.declined.listen(_onDeclined),
    ]);
    _onSession();
  }

  final HubSession session;
  final AppSettings settings;
  final WatchTogether watch;
  final GlobalKey<ScaffoldMessengerState> messenger;
  late final Presence presence;
  final List<StreamSubscription<JoinRequest>> _subs = [];

  Playable? _playable;
  bool _paused = false;

  /// A player is open, so the bubble moves out of the controls' way.
  bool get playerOpen => _playable != null;

  /// The open player's controls are showing; the bubble shows and hides
  /// with them.
  bool get playerControls => _playerControls;
  bool _playerControls = true;

  void playerControlsShown(bool shown) {
    if (shown == _playerControls) return;
    _playerControls = shown;
    notifyListeners();
  }

  /// Goes up each time someone asks to join, so the bubble can open.
  int get askedCount => _askedCount;
  int _askedCount = 0;

  /// Requests being answered or sent right now, by request or user id.
  final Set<String> busy = {};

  /// The player reports what it has open and whether it's paused.
  void playerState(Playable playable, {required bool paused}) {
    final opened = _playable == null;
    _playable = playable;
    _paused = paused;
    _update();
    if (opened) notifyListeners();
  }

  /// Where the open player is, for the admin's Tracearr.
  void playerPlayback(Playable playable, PlaybackInfo? Function() read) {
    if (identical(_playable, playable)) presence.playback = read;
  }

  void playerClosed(Playable playable) {
    if (!identical(_playable, playable)) return;
    _playable = null;
    presence.playback = null;
    _playerControls = true;
    _update();
    notifyListeners();
  }

  void _update() {
    final p = _playable;
    final room = watch.room;
    presence.setWatching(
      p == null
          ? null
          : NowWatching(
              title: p.meta.name,
              episode: _episode(p.video),
              metaType: p.meta.type,
              metaId: p.meta.id,
              paused: _paused,
              room: room != null && room.inRoom ? room.rawCode : null,
              poster: (p.meta.poster ?? '').startsWith('https://') ? p.meta.poster : null,
            ),
    );
  }

  static String? _episode(StremioVideo? v) {
    if (v == null) return null;
    final number = v.season != null && v.episode != null ? 'S${v.season} E${v.episode}' : null;
    return [?number, if (v.title.isNotEmpty) v.title].join(' · ');
  }

  Future<void> _busy(String key, Future<void> Function() work) async {
    busy.add(key);
    notifyListeners();
    try {
      await work();
    } on HubException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast(partyErrorText(e));
    } finally {
      busy.remove(key);
      notifyListeners();
    }
  }

  Future<void> ask(Person person) => _busy(person.id, () async {
    await presence.ask(person.id);
    _toast('Asked ${person.name} to let you join');
  });

  Future<void> cancel(JoinRequest request) => _busy(request.person.id, () => presence.cancel(request));

  /// Lets [request]'s sender in, starting a watch party first if there isn't
  /// one. The player shares what it plays with the new room by itself.
  Future<void> accept(JoinRequest request) => _busy(request.id, () async {
    var room = watch.room;
    if (room == null || !room.inRoom) {
      await watch.create();
      room = watch.room;
    }
    await presence.answer(request, accept: true, room: room?.rawCode);
    _toast('${request.person.name} is joining');
  });

  Future<void> decline(JoinRequest request) => _busy(request.id, () => presence.answer(request, accept: false));

  static String _plain(String code) => code.replaceAll(RegExp('[^A-Za-z0-9]'), '').toUpperCase();

  Future<void> _onAccepted(JoinRequest request) async {
    final code = request.room;
    if (code == null) return;
    final current = watch.room;
    if (current != null && current.inRoom && _plain(current.rawCode ?? '') == _plain(code)) return;
    _toast('${request.person.name} let you in. Joining…');
    await _busy(request.person.id, () async {
      await watch.join(code);
      await presence.cancel(request);
    });
  }

  void _onAsked(JoinRequest request) {
    _askedCount++;
    notifyListeners();
    if (!settings.get(Settings.showBubble)) {
      messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text('${request.person.name} wants to join you'),
          duration: const Duration(seconds: 20),
          action: SnackBarAction(label: 'Let in', onPressed: () => unawaited(accept(request))),
        ),
      );
    }
  }

  void _onDeclined(JoinRequest request) => _toast("${request.person.name} can't right now");

  void _toast(String text) {
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  void _onSession() {
    if (session.status == SessionStatus.signedIn) {
      presence.start();
    } else {
      presence.stop();
      presence.clear();
    }
  }

  void _onSettings() {
    presence.share = settings.get(Settings.shareActivity);
    notifyListeners();
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    settings.removeListener(_onSettings);
    watch.removeListener(_update);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    presence.dispose();
    super.dispose();
  }
}
