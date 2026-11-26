import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;

import 'fixtures/stremio.dart' as fx;

String contract(String name) => File('../../core/contract/$name').readAsStringSync();

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

/// A Hub plus the catalog its config points at.
class FakeServers {
  int configStatus = 200;
  final requests = <http.Request>[];
  Map<String, Object> catalogRoutes = {};

  http.Client client() => MockClient((request) async {
    requests.add(request);
    final url = request.url.toString();
    const catalog = 'https://tg.example.com/stremio/abc123';
    if (url.startsWith(catalog)) {
      final body = catalogRoutes[url.substring(catalog.length)];
      return body == null ? http.Response('nope', 404) : jsonResponse(body);
    }
    return switch (request.url.path) {
      HubPaths.login => http.Response(contract('login_response.json'), 200),
      HubPaths.config =>
        configStatus == 200
            ? http.Response(contract('config_response.json'), 200)
            : http.Response(contract('error_response.json'), configStatus),
      HubPaths.logout => http.Response(contract('ok_response.json'), 200),
      HubPaths.voiceToken => http.Response(contract('voice_token_response.json'), 200),
      _ => http.Response('{"error":"Not found"}', 404),
    };
  });
}

void main() {
  group('HubSession', () {
    test('no saved session means signed out', () async {
      final session = HubSession(store: MemorySessionStore(), deviceName: 'PC', httpClient: FakeServers().client);
      await session.restore();
      expect(session.status, SessionStatus.signedOut);
    });

    test('sign in saves the device token and sets up the catalog', () async {
      final store = MemorySessionStore();
      final servers = FakeServers();
      final session = HubSession(store: store, deviceName: 'PC', httpClient: servers.client);
      await session.signIn(address: 'hub.example.com', username: ' alice ', password: 'pw');
      expect(session.status, SessionStatus.signedIn);
      expect(store.session!.hubUrl, 'https://hub.example.com');
      expect(store.session!.token, isNotEmpty);
      expect(jsonDecode(servers.requests.first.body)['username'], 'alice');
      expect(jsonDecode(servers.requests.first.body)['device_name'], 'PC');
      expect(session.catalog!.baseUrl, 'https://tg.example.com/stremio/abc123');
      expect(session.voiceAvailable, isTrue);
    });

    test('a saved session the Hub rejects signs out with the reason', () async {
      final store = MemorySessionStore(
        const StoredSession(hubUrl: 'https://hub.example.com', token: 't', username: 'a'),
      );
      final servers = FakeServers()..configStatus = 401;
      final session = HubSession(store: store, deviceName: 'PC', httpClient: servers.client);
      await session.restore();
      expect(session.status, SessionStatus.signedOut);
      expect(session.problem, isNotNull);
      expect(store.session, isNull);
    });

    test('an unreachable Hub keeps the session for a retry', () async {
      final store = MemorySessionStore(
        const StoredSession(hubUrl: 'https://hub.example.com', token: 't', username: 'a'),
      );
      final session = HubSession(
        store: store,
        deviceName: 'PC',
        httpClient: () => MockClient((_) async => throw const SocketException('down')),
      );
      await session.restore();
      expect(session.status, SessionStatus.signedIn);
      expect(session.problem, contains("Couldn't reach"));
      expect(store.session, isNotNull);
    });

    test('sign out forgets the device', () async {
      final store = MemorySessionStore();
      final session = HubSession(store: store, deviceName: 'PC', httpClient: FakeServers().client);
      await session.signIn(address: 'https://hub.example.com', username: 'alice', password: 'pw');
      await session.signOut();
      expect(session.status, SessionStatus.signedOut);
      expect(store.session, isNull);
      expect(session.catalog, isNull);
    });
  });

  group('home rows', () {
    test('one row per catalog that has items, titled with its type', () async {
      final servers = FakeServers()
        ..catalogRoutes = {
          '/manifest.json': fx.manifest,
          '/catalog/movie/latest_movies.json': {
            'metas': [fx.catalogItem],
          },
          '/catalog/series/top_series.json': {'metas': <Object>[]},
        };
      final client = StremioClient(baseUrl: 'https://tg.example.com/stremio/abc123', httpClient: servers.client());
      final rows = await loadHomeRows(client);
      expect(rows.map((r) => r.title), ['Movies · Recently Added']);
      expect(rows.single.items.single.name, 'Inception');
    });

    test('pager stops at an empty or repeated page', () async {
      final servers = FakeServers()
        ..catalogRoutes = {
          '/catalog/movie/latest_movies.json': {
            'metas': [fx.catalogItem],
          },
          '/catalog/movie/latest_movies/skip=1.json': {
            'metas': [fx.catalogItem],
          },
        };
      final client = StremioClient(baseUrl: 'https://tg.example.com/stremio/abc123', httpClient: servers.client());
      final pager = CatalogPager(client, const StremioCatalog(type: 'movie', id: 'latest_movies', name: 'x'));
      expect(await pager.loadMore(), isTrue);
      expect(await pager.loadMore(), isFalse);
      expect(pager.done, isTrue);
      expect(pager.items, hasLength(1));
    });
  });

  group('watch party resolver', () {
    final meta = StremioMeta.fromJson((fx.seriesMeta['meta'] as Map).cast<String, dynamic>());
    final stream = StremioStream.fromJson((fx.streams['streams'] as List).first as Map<String, dynamic>)!;
    final episode = meta.videos.firstWhere((v) => v.id == 'tt0903747:1:1');
    final playable = Playable(meta: meta, video: episode, stream: stream);

    test('the descriptor names the episode and carries the file size', () {
      final media = mediaFor(playable, 3000000);
      expect(owp.checkMedia(media), isNull);
      expect(media.kind, owp.MediaKind.episode);
      expect(media.series!.ids['imdb'], 'tt0903747');
      expect([media.season, media.episode], [1, 1]);
      expect(media.file!.sizeBytes, stream.sizeBytes);
    });

    test('finds the same episode and trusts a same-size stream without probing', () async {
      final servers = FakeServers()
        ..catalogRoutes = {
          '/meta/series/tt0903747.json': fx.seriesMeta,
          '/stream/series/tt0903747:1:1.json': fx.streams,
        };
      final client = StremioClient(baseUrl: 'https://tg.example.com/stremio/abc123', httpClient: servers.client());
      var probed = 0;
      final resolver = StremioResolver(client, probe: (_, _) async => ++probed);
      final candidates = await resolver.resolve(mediaFor(playable, 3000000), _NeverCancelled());
      expect(candidates, hasLength(1));
      expect(candidates.single.durationMs, 3000000);
      expect(candidates.single.probe, isNull);
      expect(candidates.single.ref.title, contains('S1 E1'));
      expect(probed, 0);
    });

    test('a different-size stream is probed', () async {
      final servers = FakeServers()
        ..catalogRoutes = {
          '/meta/series/tt0903747.json': fx.seriesMeta,
          '/stream/series/tt0903747:1:1.json': fx.streams,
        };
      final client = StremioClient(baseUrl: 'https://tg.example.com/stremio/abc123', httpClient: servers.client());
      final resolver = StremioResolver(client, probe: (_, _) async => 1234);
      final hostMedia = mediaFor(
        Playable(
          meta: meta,
          video: episode,
          stream: const StremioStream(url: 'https://x', sizeBytes: 1),
        ),
        3000000,
      );
      final candidates = await resolver.resolve(hostMedia, _NeverCancelled());
      expect(candidates.single.durationMs, isNull);
      expect(await candidates.single.probe!(_NeverCancelled()), 1234);
    });

    test('descriptors from other apps are found by IMDb id', () {
      const movie = owp.Media(kind: owp.MediaKind.movie, title: 'Inception', ids: {'imdb': 'tt1375666'}, durationMs: 1);
      expect(StremioResolver.lookupFor(movie), (type: 'movie', metaId: 'tt1375666', streamId: 'tt1375666'));
      const episodeMedia = owp.Media(
        kind: owp.MediaKind.episode,
        title: 'Pilot',
        series: owp.Series(title: 'Breaking Bad', ids: {'imdb': 'tt0903747'}),
        season: 1,
        episode: 1,
        durationMs: 1,
      );
      expect(StremioResolver.lookupFor(episodeMedia)?.streamId, 'tt0903747:1:1');
      const unknown = owp.Media(kind: owp.MediaKind.video, title: 'Home video', durationMs: 1);
      expect(StremioResolver.lookupFor(unknown), isNull);
    });
  });

  group('VoiceChat', () {
    test('a direct grant joins peer to peer with the relay, not LiveKit', () async {
      final direct = <VoiceTokenResponse>[];
      var livekit = 0;
      final voice = VoiceChat(
        token: (_) async =>
            VoiceTokenResponse.fromJson(jsonDecode(contract('voice_token_response_direct.json')) as Json),
        available: () => true,
        connect:
            ({
              required url,
              required token,
              required micEnabled,
              micDeviceId,
              volumes = const {},
              otherVolume = 1,
            }) async {
              livekit++;
              return FakeVoiceSession(micEnabled);
            },
        connectDirect:
            ({
              required grant,
              required roomCode,
              required micEnabled,
              micDeviceId,
              volumes = const {},
              otherVolume = 1,
            }) async {
              direct.add(grant);
              expect(roomCode, 'ABC123');
              return FakeVoiceSession(micEnabled);
            },
      );
      await voice.roomChanged('ABC123');
      expect(voice.connected, isTrue);
      expect(livekit, 0);
      expect(direct.single.iceServers.last.urls, contains('turn:203.0.113.5:3478?transport=udp'));
      expect(direct.single.identity, 'u1:d1');
      await voice.roomChanged(null);
    });

    test('a direct grant without direct support says so', () async {
      final voice = VoiceChat(
        token: (_) async =>
            VoiceTokenResponse.fromJson(jsonDecode(contract('voice_token_response_direct.json')) as Json),
        available: () => true,
        retryDelays: const [],
      );
      await voice.roomChanged('ABC123');
      expect(voice.status, VoiceStatus.failed);
      expect(voice.error, contains('direct voice'));
    });

    test('joins muted on entering a room, leaves with it, and rejoins on the next visit', () async {
      final tokens = <String>[];
      final sessions = <FakeVoiceSession>[];
      final voice = VoiceChat(
        token: (code) async {
          tokens.add(code);
          return VoiceTokenResponse.fromJson(jsonDecode(contract('voice_token_response.json')) as Json);
        },
        available: () => true,
        connect:
            ({
              required url,
              required token,
              required micEnabled,
              micDeviceId,
              volumes = const {},
              otherVolume = 1,
            }) async => (FakeVoiceSession(micEnabled)..also(sessions.add)),
      );
      await voice.roomChanged('ABC123');
      expect(tokens, ['ABC123']);
      expect(voice.connected, isTrue);
      expect(voice.micEnabled, isFalse);

      await voice.leave();
      expect(sessions.single.closed, isTrue);
      await voice.roomChanged(null);
      await voice.roomChanged('ABC123');
      expect(tokens, ['ABC123', 'ABC123'], reason: 'a new visit to the room joins again');

      await voice.roomChanged(null);
      expect(voice.status, VoiceStatus.off);
      expect(sessions.last.closed, isTrue);
    });

    test('per-person volume is scaled by the overall voice volume and saved', () async {
      final sessions = <FakeVoiceSession>[];
      Map<String, double>? saved;
      final voice = VoiceChat(
        token: (_) async => VoiceTokenResponse.fromJson(jsonDecode(contract('voice_token_response.json')) as Json),
        available: () => true,
        voiceVolume: 0.5,
        onVolumesChanged: (v) => saved = v,
        connect:
            ({
              required url,
              required token,
              required micEnabled,
              micDeviceId,
              volumes = const {},
              otherVolume = 1,
            }) async => (FakeVoiceSession(micEnabled)..also(sessions.add)),
      );
      await voice.roomChanged('ROOM1');
      await voice.setPersonVolume('bob', 1.6);
      expect(sessions.single.volumes['bob'], 0.8, reason: '1.6 × 0.5');
      expect(sessions.single.others, 0.5, reason: 'everyone else, including later arrivals');
      expect(saved, {'bob': 1.6});
      expect(voice.personVolume('bob'), 1.6);
      await voice.setMicDevice('usb-mic');
      expect(sessions.single.mic, 'usb-mic');
    });

    VoiceChat fakeVoice(List<FakeVoiceSession> sessions, {bool joinMuted = true, Object? micFails}) => VoiceChat(
      token: (_) async => VoiceTokenResponse.fromJson(jsonDecode(contract('voice_token_response.json')) as Json),
      available: () => true,
      joinMuted: joinMuted,
      retryDelays: const [Duration.zero, Duration.zero],
      connect:
          ({
            required url,
            required token,
            required micEnabled,
            micDeviceId,
            volumes = const {},
            otherVolume = 1,
          }) async => (FakeVoiceSession(micEnabled)
            ..micFails = micFails
            ..also(sessions.add)),
    );

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

    test('a mic that will not turn on leaves voice connected for listening', () async {
      final sessions = <FakeVoiceSession>[];
      final voice = fakeVoice(sessions, joinMuted: false, micFails: Exception('NotAllowedError'));
      await voice.roomChanged('ROOM1');
      expect(voice.connected, isTrue);
      expect(voice.micEnabled, isFalse);
      expect(voice.micError, contains('Privacy'));

      sessions.single.micFails = null;
      await voice.setMic(true);
      expect(voice.micEnabled, isTrue);
      expect(voice.micError, isNull);
    });

    test('rejoins by itself after a drop, with the mic as it was', () async {
      final sessions = <FakeVoiceSession>[];
      final voice = fakeVoice(sessions);
      await voice.roomChanged('ROOM1');
      await voice.setMic(true);
      sessions.single.drop();
      await settle();
      expect(sessions.first.closed, isTrue, reason: 'the dropped connection is cleaned up');
      expect(sessions, hasLength(2));
      expect(voice.connected, isTrue);
      expect(voice.micEnabled, isTrue);
    });

    test('does not rejoin when removed, or after leaving the room', () async {
      final sessions = <FakeVoiceSession>[];
      final voice = fakeVoice(sessions);
      await voice.roomChanged('ROOM1');
      sessions.single.drop(retry: false);
      await settle();
      expect(sessions, hasLength(1));
      expect(voice.status, VoiceStatus.failed);

      await voice.join();
      sessions.last.drop();
      await voice.roomChanged(null);
      await settle();
      expect(sessions, hasLength(2));
      expect(voice.status, VoiceStatus.off);
    });

    test('stops rejoining when every attempt fails', () async {
      var calls = 0;
      final voice = VoiceChat(
        token: (_) async {
          if (++calls > 1) throw const HubException('offline');
          return VoiceTokenResponse.fromJson(jsonDecode(contract('voice_token_response.json')) as Json);
        },
        available: () => true,
        retryDelays: const [Duration.zero, Duration.zero],
        connect:
            ({
              required url,
              required token,
              required micEnabled,
              micDeviceId,
              volumes = const {},
              otherVolume = 1,
            }) async => FakeVoiceSession(micEnabled)..also((s) => Future<void>.delayed(Duration.zero, s.drop)),
      );
      await voice.roomChanged('ROOM1');
      await settle();
      expect(calls, 3, reason: 'the first join, then one per retry delay');
      expect(voice.status, VoiceStatus.failed);
      expect(voice.rejoining, isFalse);
    });

    test('switching back to the system default mic applies at once', () async {
      final sessions = <FakeVoiceSession>[];
      final voice = fakeVoice(sessions);
      await voice.roomChanged('ROOM1');
      await voice.setMicDevice('usb-mic');
      await voice.setMicDevice(null);
      expect(sessions.single.mic, '');
    });

    test('matches party people to voice by peer id, and by name only when unique', () async {
      final sessions = <FakeVoiceSession>[];
      final voice = fakeVoice(sessions);
      await voice.setPartyPeer('peer-me');
      await voice.roomChanged('ROOM1');
      await settle();
      expect(sessions.single.partyPeer, 'peer-me');
      VoiceMember m(String id, String name, {String? peer}) =>
          VoiceMember(identity: id, name: name, isLocal: false, speaking: false, muted: true, partyPeer: peer);
      sessions.single.members = [
        m('u1:d1', 'Sam', peer: 'p1'),
        m('u2:d2', 'Sam', peer: 'p2'),
        m('u3:d3', 'Ann'),
        m('u4:d4', 'Bo'),
        m('u5:d5', 'Bo'),
      ];
      expect(voice.memberForPeer('p2', 'Sam')?.identity, 'u2:d2');
      expect(voice.memberForPeer('p9', 'Ann')?.identity, 'u3:d3', reason: 'an older app: by name');
      expect(voice.memberForPeer('p9', 'Bo'), isNull, reason: 'two Bos without peer ids: no guess');
    });

    test('shows the Hub error when there is no token', () async {
      final voice = VoiceChat(
        token: (_) async => throw const HubException("Voice chat isn't set up on this Hub.", status: 503),
        available: () => true,
      );
      await voice.roomChanged('ROOM1');
      expect(voice.status, VoiceStatus.failed);
      expect(voice.error, "Voice chat isn't set up on this Hub.");
    });
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

class FakeVoiceSession implements VoiceSession {
  FakeVoiceSession(this.micEnabled);

  @override
  bool micEnabled;
  bool closed = false;
  final _changes = StreamController<void>.broadcast();
  final _dropped = Completer<bool>();

  /// Set to make turning the mic on fail, as a blocked or missing mic does.
  Object? micFails;
  String? partyPeer;

  /// The connection drops; [retry] as LiveKit's reason would say.
  void drop({bool retry = true}) => _dropped.complete(retry);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> get dropped => _dropped.future;

  @override
  List<VoiceMember> members = const [];

  @override
  double get micLevel => micEnabled ? 0.5 : 0;

  var volumes = <String, double>{};
  double others = 1;
  String? mic;

  @override
  Future<void> setVolumes(Map<String, double> perPerson, double others) async {
    volumes = perPerson;
    this.others = others;
  }

  @override
  Future<void> setMicDevice(String deviceId) async => mic = deviceId;

  @override
  Future<void> setMicEnabled(bool enabled) async {
    if (enabled && micFails != null) throw micFails!;
    micEnabled = enabled;
  }

  @override
  Future<void> setPartyPeer(String peerId) async => partyPeer = peerId;

  @override
  Future<void> close() async => closed = true;
}

class _NeverCancelled implements owp.Cancellation {
  @override
  bool get isCancelled => false;

  @override
  Future<void> get whenCancelled => Completer<void>().future;
}
