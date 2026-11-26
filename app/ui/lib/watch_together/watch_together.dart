import 'dart:async';
import 'dart:convert';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;

import '../screens/player_screen.dart';
import 'mpv_adapter.dart';

/// The app's watch party and its voice chat.
///
/// Holds at most one [WatchRoom]. When the room picks a title for this user
/// (everyone but the host), opens the player on it.
class WatchTogether extends ChangeNotifier {
  WatchTogether({required this.session, required this.navigator, required this.settings}) {
    voice = VoiceChat(
      token: session.voiceToken,
      available: () => session.voiceAvailable,
      connectDirect:
          ({required grant, required roomCode, required micEnabled, micDeviceId, volumes = const {}, otherVolume = 1}) {
            final hub = session.hub;
            if (hub == null) throw Exception('Sign in to use voice chat.');
            return connectDirectSession(
              grant: grant,
              roomCode: roomCode,
              signaling: HubVoiceSignaling(hub),
              selfName: session.config?.user.name ?? 'Me',
              micEnabled: micEnabled,
              micDeviceId: micDeviceId,
              volumes: volumes,
              otherVolume: otherVolume,
            );
          },
      joinMuted: settings.get(Settings.joinMuted),
      micDeviceId: settings.get(Settings.voiceMic),
      voiceVolume: settings.get(Settings.voiceVolume) / 100,
      personVolumes: _readVolumes(settings.get(Settings.voicePeople)),
      onVolumesChanged: (v) => settings.set(Settings.voicePeople, jsonEncode(v)),
    );
    voice.addListener(notifyListeners);
    session.addListener(_onSession);
    settings.addListener(_onSettings);
  }

  final HubSession session;
  final AppSettings settings;

  static Map<String, double> _readVolumes(String json) {
    try {
      return {for (final e in (jsonDecode(json) as Map).entries) e.key as String: (e.value as num).toDouble()};
    } catch (_) {
      return {};
    }
  }

  void _onSettings() {
    voice.joinMuted = settings.get(Settings.joinMuted);
    final mic = settings.get(Settings.voiceMic);
    if (mic != (voice.micDeviceId ?? '')) unawaited(voice.setMicDevice(mic));
    final volume = settings.get(Settings.voiceVolume) / 100;
    if (volume != voice.voiceVolume) unawaited(voice.setVoiceVolume(volume));
  }

  final GlobalKey<NavigatorState> navigator;
  late final VoiceChat voice;

  WatchRoom? _room;
  WatchRoom? get room => _room;
  StreamSubscription<owp.PartyEvent>? _events;

  /// What the player screen has open, so the room's choice isn't opened twice.
  Playable? get playing => _playing;
  Playable? _playing;
  set playing(Playable? value) {
    final closed = _playing;
    _playing = value;
    // A guest who closes the player on the room's title leaves the party, so
    // the room doesn't open it again; to come back they ask to join again.
    final room = _room;
    final choice = room?.choice;
    if (value == null && room != null && !room.isHost && closed != null && choice != null && closed.url == choice.url) {
      notices.add('You left the watch party');
      unawaited(leave());
    }
  }

  /// The last thing worth telling the user, such as someone joining.
  final notices = StreamController<String>.broadcast();

  WatchRoom _newRoom() {
    final catalog = session.catalog;
    if (catalog == null) throw StateError('No catalog yet');
    final room = WatchRoom(catalog: catalog, name: session.config?.user.name ?? 'Couchmate', probe: probeDuration);
    room.addListener(_onRoom);
    _events = room.events.listen(_onEvent);
    return room;
  }

  /// Creates a room and returns its code. Throws [owp.PartyException].
  Future<String> create() async {
    await leave();
    final room = _room = _newRoom();
    notifyListeners();
    try {
      return await room.create();
    } catch (_) {
      await leave();
      rethrow;
    }
  }

  /// Joins by code. Throws [owp.PartyException].
  Future<void> join(String code) async {
    await leave();
    final room = _room = _newRoom();
    notifyListeners();
    try {
      await room.join(code);
    } catch (_) {
      await leave();
      rethrow;
    }
  }

  Future<void> leave() async {
    final room = _room;
    if (room == null) return;
    _room = null;
    room.removeListener(_onRoom);
    await _events?.cancel();
    _events = null;
    await room.close();
    await voice.roomChanged(null);
    notifyListeners();
  }

  String? _lastCode;

  void _onRoom() {
    final room = _room;
    if (room == null) return;
    final code = room.inRoom ? room.rawCode : null;
    if (code != _lastCode) {
      _lastCode = code;
      unawaited(voice.roomChanged(code));
    }
    unawaited(voice.setPartyPeer(room.state.peerId));
    _openChoice(room);
    notifyListeners();
  }

  /// Opens the room's choice in the player unless it's already open there.
  void _openChoice(WatchRoom room) {
    final choice = room.choice;
    if (choice == null || room.isHost) return;
    final current = _playing;
    if (current != null && current.url == choice.url) return;
    _playing = choice;
    final nav = navigator.currentState;
    if (nav == null) return;
    if (current != null) {
      nav.pushReplacement(MaterialPageRoute(builder: (_) => PlayerScreen(playable: choice)));
    } else {
      nav.push(MaterialPageRoute(builder: (_) => PlayerScreen(playable: choice)));
    }
  }

  void _onEvent(owp.PartyEvent event) {
    final text = switch (event) {
      owp.ParticipantJoinedEvent(:final participant) => '${participant.name} joined',
      owp.ParticipantLeftEvent(:final participant) => '${participant.name} left',
      owp.EndedEvent(:final reason) => switch (reason) {
        owp.EndReason.ended => 'The host ended the watch party',
        owp.EndReason.kicked => 'You were removed from the watch party',
        owp.EndReason.expired => 'The watch party expired',
        owp.EndReason.lost => 'Lost the connection to the watch party',
        _ => null,
      },
      owp.ResolveFailedEvent() => "Couldn't find your copy of what the room is watching",
      owp.PlayBlockedEvent() => 'Press play to start',
      _ => null,
    };
    if (text != null) notices.add(text);
    if (event is owp.EndedEvent) unawaited(leave());
  }

  void _onSession() {
    if (session.status == SessionStatus.signedOut) unawaited(leave());
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    settings.removeListener(_onSettings);
    unawaited(leave());
    voice.dispose();
    notices.close();
    super.dispose();
  }
}

/// Shown for a [owp.PartyException] code.
String partyErrorText(Object e) {
  if (e is! owp.PartyException) return 'Something went wrong.';
  return switch (e.code) {
    'room_not_found' => 'No room has that code.',
    'invalid_code' => "That isn't a room code.",
    'room_full' => 'That room is full.',
    'room_locked' => 'That room is locked.',
    'unreachable' => "Couldn't reach the watch party server.",
    'relay_full' => 'The watch party server is busy. Try again soon.',
    _ => "Couldn't connect to the watch party (${e.code}).",
  };
}
