import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub/api.dart';
import 'voice_session.dart';

enum VoiceStatus { off, connecting, connected, failed }

/// Voice chat for the watch party room the user is in. Joins the room's
/// voice channel (muted) each time the user enters a room, and leaves with
/// it. The Hub hands out the LiveKit token, so no keys live in the app.
///
/// Call [roomChanged] whenever the watch room's code changes (null when the
/// user leaves the room).
class VoiceChat extends ChangeNotifier {
  VoiceChat({
    required Future<VoiceTokenResponse> Function(String roomCode) token,
    required bool Function() available,
    VoiceSessionFactory? connect,
    this.joinMuted = true,
    this.micDeviceId,
    Map<String, double>? personVolumes,
    this.voiceVolume = 1,
    this.onVolumesChanged,
  }) : _personVolumes = {...?personVolumes},
       _token = token,
       _available = available,
       _connect = connect ?? connectLiveKitSession;

  final Future<VoiceTokenResponse> Function(String roomCode) _token;
  final bool Function() _available;
  final VoiceSessionFactory _connect;
  bool joinMuted;

  /// The microphone to use; null for the system default.
  String? micDeviceId;

  /// Everyone's voice is scaled by this (1 = as sent).
  double voiceVolume;
  final Map<String, double> _personVolumes;

  /// Called with the per-person volumes after a change, to save them.
  final void Function(Map<String, double>)? onVolumesChanged;

  VoiceSession? _session;
  StreamSubscription<void>? _changes;
  VoiceStatus _status = VoiceStatus.off;
  String? _error;
  String? _room;
  int _generation = 0;
  bool _disposed = false;

  VoiceStatus get status => _status;
  String? get error => _error;
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

  Future<void> setMicDevice(String? deviceId) async {
    micDeviceId = deviceId;
    if (deviceId != null && deviceId.isNotEmpty) await _session?.setMicDevice(deviceId);
    _notify();
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
    if (code != null && available) await join();
    _notify();
  }

  /// Joins the current room's voice channel.
  Future<void> join() async {
    final room = _room;
    if (room == null || _session != null || _status == VoiceStatus.connecting) return;
    final generation = ++_generation;
    _status = VoiceStatus.connecting;
    _error = null;
    _notify();
    try {
      final grant = await _token(room);
      final session = await _connect(
        url: grant.url,
        token: grant.token,
        micEnabled: !joinMuted,
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
      unawaited(session.dropped.then((_) => _onDropped(generation)));
      _status = VoiceStatus.connected;
    } catch (e) {
      if (generation != _generation) return;
      _status = VoiceStatus.failed;
      _error = e is Exception ? _message(e) : '$e';
    }
    _notify();
  }

  /// Leaves voice but stays in the watch room. [join] rejoins.
  Future<void> leave() async {
    await _leave();
    _notify();
  }

  Future<void> setMic(bool enabled) async {
    await _session?.setMicEnabled(enabled);
    _notify();
  }

  Future<void> _leave() async {
    _generation++;
    final session = _session;
    _session = null;
    await _changes?.cancel();
    _changes = null;
    _status = VoiceStatus.off;
    await session?.close();
  }

  void _onDropped(int generation) {
    if (generation != _generation) return;
    _session = null;
    unawaited(_changes?.cancel());
    _changes = null;
    _status = VoiceStatus.failed;
    _error = 'Voice chat disconnected.';
    _notify();
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
