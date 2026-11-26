import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub/api.dart';
import 'direct_voice.dart';
import 'voice_session.dart';

enum VoiceStatus { off, connecting, connected, failed }

/// What to tell the user when the microphone won't turn on, from [error].
String micErrorText(Object error) {
  final text = '$error'.toLowerCase();
  if (text.contains('notfound') || text.contains('not found') || text.contains('no device')) {
    return 'No microphone found. Plug one in or pick another in Settings › Voice. You can still listen.';
  }
  return "Couldn't turn on your microphone. In Windows Settings › Privacy & security › Microphone, allow "
      'desktop apps to use it, and check no other app holds it. You can still listen.';
}

/// Voice chat for the watch party room the user is in. Joins the room's
/// voice channel (muted) each time the user enters a room, and leaves with
/// it. The Hub hands out the LiveKit token, so no keys live in the app. When
/// the Hub says voice is direct, [connectDirect] joins peer to peer instead.
///
/// Call [roomChanged] whenever the watch room's code changes (null when the
/// user leaves the room).
class VoiceChat extends ChangeNotifier {
  VoiceChat({
    required Future<VoiceTokenResponse> Function(String roomCode) token,
    required bool Function() available,
    VoiceSessionFactory? connect,
    DirectVoiceFactory? connectDirect,
    this.joinMuted = true,
    this.micDeviceId,
    Map<String, double>? personVolumes,
    this.voiceVolume = 1,
    this.onVolumesChanged,
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
  }) : _personVolumes = {...?personVolumes},
       _token = token,
       _available = available,
       _connect = connect ?? connectLiveKitSession,
       _connectDirect = connectDirect;

  final Future<VoiceTokenResponse> Function(String roomCode) _token;
  final bool Function() _available;
  final VoiceSessionFactory _connect;
  final DirectVoiceFactory? _connectDirect;
  bool joinMuted;

  /// The microphone to use; null for the system default.
  String? micDeviceId;

  /// Everyone's voice is scaled by this (1 = as sent).
  double voiceVolume;
  final Map<String, double> _personVolumes;

  /// Called with the per-person volumes after a change, to save them.
  final void Function(Map<String, double>)? onVolumesChanged;

  /// How long to wait before each automatic rejoin after the connection
  /// drops. After the last one, the user rejoins by hand.
  final List<Duration> retryDelays;

  VoiceSession? _session;
  StreamSubscription<void>? _changes;
  VoiceStatus _status = VoiceStatus.off;
  String? _error;
  String? _room;
  String? _partyPeer;
  String? _micError;
  int _generation = 0;
  bool _disposed = false;
  Timer? _retry;
  int _retries = 0;

  VoiceStatus get status => _status;
  String? get error => _error;

  /// Why the microphone couldn't be turned on, while it stays off. Voice
  /// still works for listening.
  String? get micError => _micError;

  /// Waiting to rejoin by itself after the connection dropped.
  bool get rejoining => _retry != null;
  bool get available => _available();
  bool get connected => _status == VoiceStatus.connected;
  bool get micEnabled => _session?.micEnabled ?? false;

  /// This user's microphone level, 0–1. Read it on a timer to draw a meter.
  double get micLevel => _session?.micLevel ?? 0;
  List<VoiceMember> get members => _session?.members ?? const [];

  /// Someone else is talking right now (for lowering the movie).
  bool get othersSpeaking => members.any((m) => !m.isLocal && m.speaking && !m.muted);

  /// [person]'s own volume, before [voiceVolume] (1 = as sent).
  double personVolume(String person) => _personVolumes[person] ?? 1;

  Future<void> setPersonVolume(String person, double volume) async {
    _personVolumes[person] = volume;
    onVolumesChanged?.call(Map.of(_personVolumes));
    await _session?.setVolumes(_effectiveVolumes, voiceVolume);
    _notify();
  }

  Future<void> setVoiceVolume(double volume) async {
    voiceVolume = volume;
    await _session?.setVolumes(_effectiveVolumes, voiceVolume);
    _notify();
  }

  /// Switches the microphone, live. Null or empty is the system default.
  Future<void> setMicDevice(String? deviceId) async {
    micDeviceId = deviceId;
    await _session?.setMicDevice(deviceId ?? '');
    _notify();
  }

  /// This user's peer id in the watch party, shared with voice so each
  /// person in the party is matched to their voice even when two have the
  /// same name.
  Future<void> setPartyPeer(String? peerId) async {
    if (peerId == _partyPeer) return;
    _partyPeer = peerId;
    if (peerId != null) await _session?.setPartyPeer(peerId);
  }

  /// The voice member for the watch party participant with [peerId] and
  /// [name]. Matches by peer id; falls back to the name only for people
  /// whose app doesn't share its peer id, and only when the name is unique.
  VoiceMember? memberForPeer(String peerId, String name) {
    final list = members;
    for (final m in list) {
      if (m.partyPeer == peerId) return m;
    }
    final byName = list.where((m) => m.partyPeer == null && m.name == name).toList();
    return byName.length == 1 ? byName.single : null;
  }

  /// The volumes to start a session with: each known person's, scaled.
  Map<String, double> get _effectiveVolumes => {for (final e in _personVolumes.entries) e.key: e.value * voiceVolume};
  String? get room => _room;

  /// The watch room is now [code] (null: not in one).
  Future<void> roomChanged(String? code) async {
    if (code == _room) return;
    await _leave();
    _room = code;
    _error = null;
    _micError = null;
    if (code != null && available) await join();
    _notify();
  }

  /// Joins the current room's voice channel.
  Future<void> join() async {
    _cancelRetry();
    _retries = 0;
    await _join(micOn: !joinMuted);
  }

  /// Connects, then turns the mic on when [micOn]. A mic that can't be
  /// turned on leaves voice connected for listening, with [micError] set.
  Future<void> _join({required bool micOn}) async {
    final room = _room;
    if (room == null || _session != null || _status == VoiceStatus.connecting) return;
    final generation = ++_generation;
    _status = VoiceStatus.connecting;
    _error = null;
    _notify();
    try {
      final grant = await _token(room);
      final direct = _connectDirect;
      if (grant.direct && direct == null) throw Exception("This app can't use direct voice.");
      final session = grant.direct
          ? await direct!(
              grant: grant,
              roomCode: room,
              micEnabled: false,
              micDeviceId: micDeviceId,
              volumes: _effectiveVolumes,
              otherVolume: voiceVolume,
            )
          : await _connect(
              url: grant.url,
              token: grant.token,
              micEnabled: false,
              micDeviceId: micDeviceId,
              volumes: _effectiveVolumes,
              otherVolume: voiceVolume,
            );
      if (generation != _generation || _disposed) {
        await session.close();
        return;
      }
      _session = session;
      _changes = session.changes.listen((_) => _notify());
      unawaited(session.dropped.then((retry) => _onDropped(generation, session, retry: retry)));
      _status = VoiceStatus.connected;
      _retries = 0;
      final peer = _partyPeer;
      if (peer != null) unawaited(session.setPartyPeer(peer).catchError((_) {}));
      if (micOn) await _turnMicOn(session);
    } catch (e) {
      if (generation != _generation) return;
      _status = VoiceStatus.failed;
      _error = e is Exception ? _message(e) : '$e';
      // A rejoin that fails tries again, until the delays run out.
      if (_retries > 0) _scheduleRetry(micOn: micOn);
    }
    _notify();
  }

  /// Leaves voice but stays in the watch room. [join] rejoins.
  Future<void> leave() async {
    await _leave();
    _notify();
  }

  /// Mutes or unmutes. When the mic can't be turned on, [micError] says why.
  Future<void> setMic(bool enabled) async {
    final session = _session;
    if (session == null) return;
    if (enabled) {
      await _turnMicOn(session);
    } else {
      _micError = null;
      await session.setMicEnabled(false);
    }
    _notify();
  }

  Future<void> _turnMicOn(VoiceSession session) async {
    try {
      await session.setMicEnabled(true);
      _micError = null;
    } catch (e) {
      _micError = micErrorText(e);
    }
  }

  Future<void> _leave() async {
    _cancelRetry();
    _retries = 0;
    _generation++;
    final session = _session;
    _session = null;
    await _changes?.cancel();
    _changes = null;
    _status = VoiceStatus.off;
    _micError = null;
    await session?.close();
  }

  void _onDropped(int generation, VoiceSession session, {required bool retry}) {
    // Free the dropped connection's resources whatever happens next.
    unawaited(session.close().catchError((_) {}));
    if (generation != _generation) return;
    final micWasOn = session.micEnabled;
    _session = null;
    unawaited(_changes?.cancel());
    _changes = null;
    _status = VoiceStatus.failed;
    _error = 'Voice chat disconnected.';
    if (retry) _scheduleRetry(micOn: micWasOn);
    _notify();
  }

  /// Rejoins after the next of [retryDelays], keeping the mic as it was.
  void _scheduleRetry({required bool micOn}) {
    _cancelRetry();
    if (_disposed || _room == null || _retries >= retryDelays.length) {
      _retries = 0;
      return;
    }
    final delay = retryDelays[_retries++];
    _error = 'Voice chat disconnected. Reconnecting…';
    _retry = Timer(delay, () {
      _retry = null;
      unawaited(_join(micOn: micOn));
    });
  }

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  String _message(Exception e) {
    final text = e.toString();
    // HubException and friends carry a readable message after the colon.
    final i = text.indexOf(': ');
    return i >= 0 ? text.substring(i + 2) : text;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_leave());
    super.dispose();
  }
}
