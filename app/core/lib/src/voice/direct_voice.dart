import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../hub/api.dart';
import '../hub/hub_client.dart';
import '../rules.dart';
import '../social/chat.dart' show ChatConnector, ChatSocket, connectChatSocket;
import 'voice_session.dart';

/// How a direct voice session reaches the others in its room: the Hub's
/// `voice/peers` and `voice/signal` calls, and `voice` frames on a live
/// socket. Tests substitute an in-memory one.
abstract class VoiceSignaling {
  /// Joins, stays in or leaves [roomCode].
  Future<VoicePeers> peers(String roomCode, {bool leaving = false});

  Future<void> send(VoiceSignalSend signal);

  /// Signals for this user's devices.
  Stream<VoiceSignal> get incoming;

  /// Opens [incoming]. Throws when the Hub can't be reached.
  Future<void> open();

  Future<void> close();
}

/// [VoiceSignaling] through the Hub. Opens its own live socket, so voice
/// doesn't depend on the chat's.
class HubVoiceSignaling implements VoiceSignaling {
  HubVoiceSignaling(this._hub, {ChatConnector connect = connectChatSocket}) : _connect = connect;

  final HubClient _hub;
  final ChatConnector _connect;
  final _incoming = StreamController<VoiceSignal>.broadcast();
  ChatSocket? _socket;
  StreamSubscription<String>? _frames;
  Timer? _ping;
  Timer? _retry;
  bool _closed = false;
  int _failures = 0;

  @override
  Stream<VoiceSignal> get incoming => _incoming.stream;

  @override
  Future<VoicePeers> peers(String roomCode, {bool leaving = false}) => _hub.voicePeers(roomCode, leaving: leaving);

  @override
  Future<void> send(VoiceSignalSend signal) => _hub.voiceSignal(signal);

  @override
  Future<void> open() async {
    final socket = await _connect(_hub.chatLiveUrl, _hub.authHeaders);
    if (_closed) {
      await socket.close();
      return;
    }
    _socket = socket;
    _failures = 0;
    _frames = socket.frames.listen(_onFrame, onDone: _onLost, onError: (_) => _onLost());
    _ping = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        _socket?.send('ping');
      } catch (_) {}
    });
  }

  void _onFrame(String frame) {
    if (frame == 'pong') return;
    try {
      final event = ChatEvent.fromJson(jsonDecode(frame) as Json);
      final voice = event.voice;
      if (event.kind == 'voice' && voice != null && !_incoming.isClosed) _incoming.add(voice);
    } catch (_) {}
  }

  void _onLost() {
    _ping?.cancel();
    unawaited(_frames?.cancel());
    _frames = null;
    _socket = null;
    if (_closed) return;
    // 1, 2, 4 … seconds, at most 30. Missed signals are made up by the
    // session's heartbeat and retries.
    final seconds = (1 << _failures.clamp(0, 5)).clamp(1, 30);
    _failures++;
    _retry = Timer(Duration(seconds: seconds), () async {
      try {
        await open();
      } catch (_) {
        _onLost();
      }
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _ping?.cancel();
    await _frames?.cancel();
    try {
      await _socket?.close();
    } catch (_) {}
    await _incoming.close();
  }
}

typedef DirectVoiceFactory =
    Future<VoiceSession> Function({
      required VoiceTokenResponse grant,
      required String roomCode,
      required bool micEnabled,
      String? micDeviceId,
      Map<String, double> volumes,
      double otherVolume,
    });

/// Joins [roomCode]'s direct voice room with [grant] (from the Hub, in
/// direct mode).
Future<VoiceSession> connectDirectSession({
  required VoiceTokenResponse grant,
  required String roomCode,
  required VoiceSignaling signaling,
  required String selfName,
  required bool micEnabled,
  String? micDeviceId,
  Map<String, double> volumes = const {},
  double otherVolume = 1,
  bool relayOnly = false,
}) async {
  final session = DirectVoiceSession._(grant, roomCode, signaling, selfName, volumes, otherVolume)
    .._relayOnly = relayOnly;
  await session._start(micEnabled, micDeviceId);
  return session;
}

/// Above this incoming level (0–1) someone counts as speaking.
const _speakingLevel = 0.02;

class _Peer {
  _Peer(this.identity, this.name);

  final String identity;
  String name;
  rtc.RTCPeerConnection? pc;
  rtc.RTCDataChannel? channel;
  rtc.RTCRtpSender? sender;
  rtc.MediaStreamTrack? track;

  /// Which offer [pc] belongs to; signals for another one are stale.
  int offer = 0;
  bool remoteSet = false;
  final List<rtc.RTCIceCandidate> pendingIce = [];
  rtc.RTCPeerConnectionState? state;
  bool muted = true;
  String? partyPeer;
  double level = 0;
  DateTime lastLoud = DateTime.fromMillisecondsSinceEpoch(0);
  int restarts = 0;
  Timer? waitForOffer;
  Timer? restart;

  bool get connected => state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected;
}

/// Voice straight between the apps in a room (a full mesh, so for a few
/// people), through the Hub's TURN relay when a direct path doesn't work.
///
/// Of each pair, the device with the smaller identity makes the offer; the
/// other asks for one with `hello` when none came. Every offer carries an
/// id that its answer and candidates repeat, so late messages from a
/// replaced connection are dropped. Mic state and the watch party peer id
/// travel on a data channel in each connection.
class DirectVoiceSession implements VoiceSession {
  DirectVoiceSession._(
    this._grant,
    this._roomCode,
    this._signaling,
    this._selfName,
    Map<String, double> volumes,
    this._others,
  ) : _volumes = {...volumes};

  final VoiceTokenResponse _grant;
  final String _roomCode;
  final VoiceSignaling _signaling;
  final String _selfName;
  Map<String, double> _volumes;
  double _others;

  late final String _room = roomForWatchCode(_roomCode) ?? _grant.room;
  String _me = '';
  final Map<String, _Peer> _peers = {};
  final _changes = StreamController<void>.broadcast();
  final _dropped = Completer<bool>();
  StreamSubscription<VoiceSignal>? _incoming;
  Timer? _heartbeat;
  Timer? _stats;
  int _heartbeatFailures = 0;
  bool _closing = false;
  int _offers = 0;

  rtc.MediaStream? _micStream;
  rtc.MediaStreamTrack? _micTrack;
  bool _micEnabled = false;
  double _micLevel = 0;
  String? _partyPeer;
  bool _localSpeaking = false;

  double _volumeOf(String identity) => _volumes[identity.split(':').first] ?? _others;

  /// Only through the relay, never direct (for testing the relay).
  bool _relayOnly = false;

  Map<String, dynamic> get _config => {
    'iceServers': [for (final s in _grant.iceServers) s.toJson()],
    'sdpSemantics': 'unified-plan',
    if (_relayOnly) 'iceTransportPolicy': 'relay',
  };

  Future<void> _start(bool micEnabled, String? micDeviceId) async {
    try {
      await _signaling.open();
      _incoming = _signaling.incoming.listen((s) => unawaited(_onSignal(s)));
      final peers = await _signaling.peers(_roomCode);
      _me = peers.identity;
      if (micDeviceId != null && micDeviceId.isNotEmpty) await setMicDevice(micDeviceId);
      _reconcile(peers.peers, joining: true);
      _heartbeat = Timer.periodic(voicePeerHeartbeat, (_) => unawaited(_beat()));
      _stats = Timer.periodic(const Duration(milliseconds: 300), (_) => unawaited(_readStats()));
      if (micEnabled) await setMicEnabled(true);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> _beat() async {
    if (_closing) return;
    try {
      final peers = await _signaling.peers(_roomCode);
      _heartbeatFailures = 0;
      _reconcile(peers.peers);
    } catch (_) {
      // Three misses in a row (over a minute): the Hub thinks we've left.
      if (++_heartbeatFailures >= 3 && !_dropped.isCompleted) _dropped.complete(true);
    }
  }

  /// Brings [_peers] in line with who the Hub says is in the room.
  void _reconcile(List<VoicePeer> list, {bool joining = false}) {
    final present = {for (final p in list) p.identity: p};
    for (final gone in _peers.keys.where((id) => !present.containsKey(id)).toList()) {
      unawaited(_remove(gone));
    }
    for (final p in list) {
      final known = _peers[p.identity];
      if (known != null) {
        known.name = p.name;
        // A pair that never connected gets another go.
        if (known.pc == null && !_offerer(p.identity)) _askForOffer(known);
        continue;
      }
      final peer = _peers[p.identity] = _Peer(p.identity, p.name);
      if (_offerer(p.identity)) {
        unawaited(_offer(peer));
      } else {
        // Joining tells them (they offer); ask too in case that was missed.
        peer.waitForOffer = Timer(Duration(seconds: joining ? 4 : 1), () => _askForOffer(peer));
      }
    }
    _changed();
  }

  bool _offerer(String other) => _me.compareTo(other) < 0;

  void _askForOffer(_Peer peer) {
    if (_closing || !_peers.containsKey(peer.identity) || peer.connected) return;
    unawaited(_send(peer.identity, 'hello'));
  }

  Future<void> _send(String to, String kind, [Object? data]) async {
    try {
      await _signaling.send(
        VoiceSignalSend(room: _roomCode, to: to, kind: kind, data: data == null ? '' : jsonEncode(data)),
      );
    } catch (_) {
      // They left, or the Hub blinked: the heartbeat sorts it out.
    }
  }

  Future<void> _onSignal(VoiceSignal s) async {
    if (_closing || s.room != _room || s.from == _me) return;
    if (s.to != null && s.to != _me) return;
    switch (s.kind) {
      case 'joined':
        final peer = _peers.putIfAbsent(s.from, () => _Peer(s.from, s.name));
        if (_offerer(s.from)) await _offer(peer);
        _changed();
      case 'left':
        await _remove(s.from);
      case 'hello':
        final peer = _peers.putIfAbsent(s.from, () => _Peer(s.from, s.name));
        if (_offerer(s.from)) await _offer(peer);
      case 'offer':
        final peer = _peers.putIfAbsent(s.from, () => _Peer(s.from, s.name));
        await _answer(peer, jsonDecode(s.data) as Json);
      case 'answer':
        final peer = _peers[s.from];
        final data = jsonDecode(s.data) as Json;
        final pc = peer?.pc;
        if (peer == null || pc == null || data['id'] != peer.offer) return;
        await pc.setRemoteDescription(rtc.RTCSessionDescription(data['sdp'] as String?, data['type'] as String?));
        await _remoteSet(peer);
      case 'ice':
        final peer = _peers[s.from];
        final data = jsonDecode(s.data) as Json;
        if (peer == null || data['id'] != peer.offer) return;
        final candidate = rtc.RTCIceCandidate(
          data['candidate'] as String?,
          data['sdpMid'] as String?,
          (data['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (peer.remoteSet && peer.pc != null) {
          await peer.pc!.addCandidate(candidate);
        } else {
          peer.pendingIce.add(candidate);
        }
    }
  }

  Future<void> _remoteSet(_Peer peer) async {
    peer.remoteSet = true;
    for (final c in peer.pendingIce) {
      try {
        await peer.pc?.addCandidate(c);
      } catch (_) {}
    }
    peer.pendingIce.clear();
  }

  /// A fresh connection for [peer], replacing any old one.
  Future<rtc.RTCPeerConnection> _newConnection(_Peer peer, int offer) async {
    await _closeConnection(peer);
    peer.offer = offer;
    final pc = await rtc.createPeerConnection(_config);
    peer.pc = pc;
    final channel = await pc.createDataChannel(
      'state',
      rtc.RTCDataChannelInit()
        ..negotiated = true
        ..id = 0,
    );
    peer.channel = channel;
    channel.onDataChannelState = (state) {
      if (state == rtc.RTCDataChannelState.RTCDataChannelOpen) _sendState(peer);
    };
    channel.onMessage = (m) => _onState(peer, m.text);
    pc.onIceCandidate = (c) {
      if (c.candidate == null || peer.offer != offer) return;
      unawaited(_send(peer.identity, 'ice', {'id': offer, ...c.toMap() as Map<String, dynamic>}));
    };
    pc.onTrack = (e) {
      if (e.track.kind != 'audio' || peer.offer != offer) return;
      peer.track = e.track;
      final volume = _volumeOf(peer.identity);
      if (volume != 1) unawaited(_apply(e.track, volume));
      _changed();
    };
    pc.onConnectionState = (state) {
      if (peer.offer != offer) return;
      peer.state = state;
      if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        peer.restarts = 0;
        peer.waitForOffer?.cancel();
      }
      if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed) _scheduleRestart(peer);
      _changed();
    };
    return pc;
  }

  void _scheduleRestart(_Peer peer) {
    peer.restart?.cancel();
    if (_closing || peer.restarts >= 5) return;
    final delay = Duration(seconds: 2 << peer.restarts.clamp(0, 4));
    peer.restarts++;
    peer.restart = Timer(delay, () {
      if (!_peers.containsKey(peer.identity) || peer.connected) return;
      if (_offerer(peer.identity)) {
        unawaited(_offer(peer));
      } else {
        _askForOffer(peer);
      }
    });
  }

  Future<void> _offer(_Peer peer) async {
    if (_closing) return;
    final id = ++_offers;
    try {
      final pc = await _newConnection(peer, id);
      final transceiver = await pc.addTransceiver(
        kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: rtc.RTCRtpTransceiverInit(direction: rtc.TransceiverDirection.SendRecv),
      );
      peer.sender = transceiver.sender;
      if (_micTrack != null) await transceiver.sender.replaceTrack(_micTrack);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      if (peer.offer != id) return;
      await _send(peer.identity, 'offer', {'id': id, 'type': offer.type, 'sdp': offer.sdp});
    } catch (_) {
      if (peer.offer == id) _scheduleRestart(peer);
    }
  }

  Future<void> _answer(_Peer peer, Json data) async {
    final id = (data['id'] as num).toInt();
    try {
      peer.waitForOffer?.cancel();
      final pc = await _newConnection(peer, id);
      await pc.setRemoteDescription(rtc.RTCSessionDescription(data['sdp'] as String?, data['type'] as String?));
      await _remoteSet(peer);
      final transceivers = await pc.getTransceivers();
      final audio =
          transceivers.where((t) => t.receiver.track?.kind == 'audio').firstOrNull ?? transceivers.firstOrNull;
      if (audio != null) {
        await audio.setDirection(rtc.TransceiverDirection.SendRecv);
        peer.sender = audio.sender;
        if (_micTrack != null) await audio.sender.replaceTrack(_micTrack);
      }
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      if (peer.offer != id) return;
      await _send(peer.identity, 'answer', {'id': id, 'type': answer.type, 'sdp': answer.sdp});
    } catch (_) {
      if (peer.offer == id) _scheduleRestart(peer);
    }
  }

  void _sendState(_Peer peer) {
    final channel = peer.channel;
    if (channel == null || channel.state != rtc.RTCDataChannelState.RTCDataChannelOpen) return;
    try {
      unawaited(
        channel.send(
          rtc.RTCDataChannelMessage(
            jsonEncode({'muted': !_micEnabled, 'name': _selfName, partyPeerAttribute: ?_partyPeer}),
          ),
        ),
      );
    } catch (_) {}
  }

  void _sendStateToAll() {
    for (final p in _peers.values) {
      _sendState(p);
    }
  }

  void _onState(_Peer peer, String text) {
    try {
      final j = jsonDecode(text) as Json;
      peer.muted = j['muted'] as bool? ?? peer.muted;
      peer.partyPeer = j[partyPeerAttribute] as String? ?? peer.partyPeer;
      final name = j['name'] as String?;
      if (name != null && name.isNotEmpty) peer.name = name;
      _changed();
    } catch (_) {}
  }

  Future<void> _closeConnection(_Peer peer) async {
    final pc = peer.pc;
    peer.pc = null;
    peer.channel = null;
    peer.sender = null;
    peer.track = null;
    peer.state = null;
    peer.remoteSet = false;
    peer.pendingIce.clear();
    try {
      await pc?.close();
    } catch (_) {}
  }

  Future<void> _remove(String identity) async {
    final peer = _peers.remove(identity);
    if (peer == null) return;
    peer.waitForOffer?.cancel();
    peer.restart?.cancel();
    await _closeConnection(peer);
    _changed();
  }

  Future<void> _readStats() async {
    if (_closing) return;
    final now = DateTime.now();
    var changed = false;
    double? micLevel;
    for (final peer in _peers.values.toList()) {
      final pc = peer.pc;
      if (pc == null || !peer.connected) continue;
      try {
        for (final r in await pc.getStats()) {
          final level = _number(r.values['audioLevel']);
          if (level == null) continue;
          if (r.type == 'inbound-rtp') {
            if (level > _speakingLevel) peer.lastLoud = now;
            if ((peer.level > _speakingLevel) != (level > _speakingLevel)) changed = true;
            peer.level = level;
          } else if (r.type == 'media-source') {
            micLevel = level;
          }
        }
      } catch (_) {}
    }
    _micLevel = _micEnabled ? (micLevel ?? 0) : 0;
    final speaking = _micEnabled && _micLevel > _speakingLevel;
    if (speaking != _localSpeaking) {
      _localSpeaking = speaking;
      changed = true;
    }
    if (changed) _changed();
  }

  static double? _number(Object? v) => switch (v) {
    num n => n.toDouble(),
    String s => double.tryParse(s),
    _ => null,
  };

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> get dropped => _dropped.future;

  @override
  bool get micEnabled => _micEnabled;

  @override
  double get micLevel => _micLevel.clamp(0, 1).toDouble();

  @override
  List<VoiceMember> get members {
    final now = DateTime.now();
    return [
      VoiceMember(
        identity: _me,
        name: _selfName,
        isLocal: true,
        speaking: _localSpeaking,
        muted: !_micEnabled,
        partyPeer: _partyPeer,
      ),
      for (final p in _peers.values)
        VoiceMember(
          identity: p.identity,
          name: p.name,
          isLocal: false,
          speaking: p.connected && !p.muted && now.difference(p.lastLoud) < const Duration(milliseconds: 600),
          muted: p.muted,
          receiving: p.connected && p.track != null && !p.muted,
          partyPeer: p.partyPeer,
        ),
    ];
  }

  @override
  Future<void> setMicEnabled(bool enabled) async {
    if (enabled) {
      if (_micTrack == null) {
        final stream = await rtc.navigator.mediaDevices.getUserMedia({
          'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
          'video': false,
        });
        final track = stream.getAudioTracks().firstOrNull;
        if (track == null) {
          await stream.dispose();
          throw Exception('NotFoundError: no microphone');
        }
        _micStream = stream;
        _micTrack = track;
        for (final p in _peers.values) {
          try {
            await p.sender?.replaceTrack(track);
          } catch (_) {}
        }
      }
      _micTrack!.enabled = true;
    } else {
      _micTrack?.enabled = false;
    }
    _micEnabled = enabled;
    if (!enabled) _micLevel = 0;
    _sendStateToAll();
    _changed();
  }

  Future<void> _apply(rtc.MediaStreamTrack track, double volume) async {
    try {
      await rtc.Helper.setVolume(volume, track);
    } catch (_) {}
  }

  @override
  Future<void> setVolumes(Map<String, double> perPerson, double others) async {
    _volumes = {...perPerson};
    _others = others;
    for (final p in _peers.values) {
      final track = p.track;
      if (track != null) await _apply(track, _volumeOf(p.identity));
    }
  }

  @override
  Future<void> setMicDevice(String deviceId) async {
    try {
      var id = deviceId;
      if (id.isEmpty) {
        final inputs = (await rtc.navigator.mediaDevices.enumerateDevices()).where((d) => d.kind == 'audioinput');
        id =
            (inputs.where((d) => d.deviceId == 'default').firstOrNull ??
                    inputs.where((d) => d.label.toLowerCase().startsWith('default')).firstOrNull ??
                    inputs.firstOrNull)
                ?.deviceId ??
            '';
      }
      if (id.isNotEmpty) await rtc.Helper.selectAudioInput(id);
    } catch (_) {}
  }

  @override
  Future<void> setPartyPeer(String peerId) async {
    if (_partyPeer == peerId) return;
    _partyPeer = peerId;
    _sendStateToAll();
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _heartbeat?.cancel();
    _stats?.cancel();
    await _incoming?.cancel();
    if (_me.isNotEmpty) {
      try {
        await _signaling.peers(_roomCode, leaving: true).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    for (final id in _peers.keys.toList()) {
      await _remove(id);
    }
    try {
      await _micTrack?.stop();
      await _micStream?.dispose();
    } catch (_) {}
    _micTrack = null;
    _micStream = null;
    await _signaling.close();
    await _changes.close();
  }
}
