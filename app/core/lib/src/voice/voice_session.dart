import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

/// Someone in the voice channel, this user included.
class VoiceMember {
  const VoiceMember({
    required this.identity,
    required this.name,
    required this.isLocal,
    required this.speaking,
    required this.muted,
    this.receiving = false,
  });

  final String identity;
  final String name;
  final bool isLocal;
  final bool speaking;
  final bool muted;

  /// Someone else's audio is reaching this device (subscribed and playing).
  final bool receiving;

  /// The person, the same on all their devices (identities are
  /// `<user id>:<device id>`).
  String get person => identity.split(':').first;
}

/// A microphone the user can pick.
class MicDevice {
  const MicDevice({required this.id, required this.label});

  final String id;
  final String label;
}

/// The microphones on this computer.
Future<List<MicDevice>> listMicrophones() async {
  try {
    final inputs = await lk.Hardware.instance.audioInputs();
    return [for (final d in inputs) MicDevice(id: d.deviceId, label: d.label.isEmpty ? 'Microphone' : d.label)];
  } catch (_) {
    return const [];
  }
}

/// One connection to a voice channel. [LiveKitVoiceSession] is the real one;
/// tests substitute a fake.
abstract class VoiceSession {
  /// Fires whenever [members] or [micEnabled] may have changed.
  Stream<void> get changes;

  /// Completes when the server or network drops the session (not on [close]).
  Future<void> get dropped;

  List<VoiceMember> get members;
  bool get micEnabled;

  /// How loud this user's microphone is right now, 0–1 (0 when muted).
  double get micLevel;

  Future<void> setMicEnabled(bool enabled);

  /// Plays each person's voice at their volume in [perPerson], and anyone
  /// else at [others] (1 is as sent, 2 twice as loud). Applies to people
  /// who join later too.
  Future<void> setVolumes(Map<String, double> perPerson, double others);

  /// Uses the microphone with this device id from now on.
  Future<void> setMicDevice(String deviceId);

  Future<void> close();
}

typedef VoiceSessionFactory =
    Future<VoiceSession> Function({
      required String url,
      required String token,
      required bool micEnabled,
      String? micDeviceId,
      Map<String, double> volumes,
      double otherVolume,
    });

Future<VoiceSession> connectLiveKitSession({
  required String url,
  required String token,
  required bool micEnabled,
  String? micDeviceId,
  Map<String, double> volumes = const {},
  double otherVolume = 1,
}) async {
  final session = LiveKitVoiceSession._(volumes, otherVolume);
  await session._connect(url, token, micEnabled, micDeviceId);
  return session;
}

class LiveKitVoiceSession implements VoiceSession {
  LiveKitVoiceSession._(Map<String, double> volumes, this._others) : _volumes = {...volumes};

  /// Volume per person, applied whenever their audio arrives.
  Map<String, double> _volumes;

  /// Volume for everyone not in [_volumes].
  double _others;

  double _volumeOf(String identity) => _volumes[identity.split(':').first] ?? _others;

  final lk.Room _room = lk.Room(
    roomOptions: const lk.RoomOptions(
      adaptiveStream: false,
      dynacast: false,
      defaultAudioCaptureOptions: lk.AudioCaptureOptions(
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
        highPassFilter: true,
      ),
    ),
  );
  late final lk.EventsListener<lk.RoomEvent> _listener = _room.createListener();
  final _changes = StreamController<void>.broadcast();
  final _dropped = Completer<void>();
  bool _closing = false;

  Future<void> _connect(String url, String token, bool micEnabled, String? micDeviceId) async {
    _room.addListener(_changed);
    _listener
      ..on<lk.RoomDisconnectedEvent>((_) {
        if (!_closing && !_dropped.isCompleted) _dropped.complete();
        _changed();
      })
      ..on<lk.ActiveSpeakersChangedEvent>((_) => _changed())
      ..on<lk.ParticipantConnectedEvent>((_) => _changed())
      ..on<lk.ParticipantDisconnectedEvent>((_) => _changed())
      ..on<lk.TrackMutedEvent>((_) => _changed())
      ..on<lk.TrackUnmutedEvent>((_) => _changed())
      ..on<lk.TrackSubscribedEvent>((e) {
        final volume = _volumeOf(e.participant.identity);
        if (volume != 1 && e.track is lk.RemoteAudioTrack) unawaited(_apply(e.track, volume));
        _changed();
      });
    try {
      await _room.connect(url, token);
      if (micDeviceId != null && micDeviceId.isNotEmpty) await setMicDevice(micDeviceId);
      if (micEnabled) await _room.localParticipant?.setMicrophoneEnabled(true);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> get dropped => _dropped.future;

  @override
  bool get micEnabled => _room.localParticipant?.isMicrophoneEnabled() ?? false;

  @override
  double get micLevel {
    final local = _room.localParticipant;
    if (local == null || !local.isMicrophoneEnabled()) return 0;
    return local.audioLevel.clamp(0, 1).toDouble();
  }

  @override
  List<VoiceMember> get members {
    final local = _room.localParticipant;
    return [
      if (local != null) _member(local, isLocal: true),
      for (final remote in _room.remoteParticipants.values) _member(remote, isLocal: false),
    ];
  }

  VoiceMember _member(lk.Participant participant, {required bool isLocal}) => VoiceMember(
    identity: participant.identity,
    name: participant.name.isEmpty ? participant.identity : participant.name,
    isLocal: isLocal,
    speaking: participant.isSpeaking,
    muted: !participant.isMicrophoneEnabled(),
    // For others: their audio track reached this device and plays.
    receiving:
        !isLocal &&
        participant is lk.RemoteParticipant &&
        participant.audioTrackPublications.any((t) => t.subscribed && !t.muted),
  );

  @override
  Future<void> setMicEnabled(bool enabled) async {
    await _room.localParticipant?.setMicrophoneEnabled(enabled);
    _changed();
  }

  Future<void> _apply(lk.Track track, double volume) async {
    try {
      await rtc.Helper.setVolume(volume, track.mediaStreamTrack);
    } catch (_) {
      // Not every platform can set a track's volume; ignore.
    }
  }

  @override
  Future<void> setVolumes(Map<String, double> perPerson, double others) async {
    _volumes = {...perPerson};
    _others = others;
    for (final p in _room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final track = pub.track;
        if (track != null) await _apply(track, _volumeOf(p.identity));
      }
    }
  }

  @override
  Future<void> setMicDevice(String deviceId) async {
    try {
      final device = (await lk.Hardware.instance.audioInputs()).where((d) => d.deviceId == deviceId).firstOrNull;
      if (device != null) await _room.setAudioInputDevice(device);
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _room.removeListener(_changed);
    try {
      await _room.disconnect();
    } finally {
      await _listener.dispose();
      await _room.dispose();
      await _changes.close();
    }
  }
}
