import 'dart:convert';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String sample(String name) => File('../../core/contract/$name').readAsStringSync();

void main() {
  const watching = NowWatching(
    title: 'Inception',
    metaType: 'movie',
    metaId: 'tt1375666',
    paused: false,
    room: 'K7MQ2X',
  );

  ({Presence presence, List<http.Request> sent}) make({String reply = 'activity.json'}) {
    final sent = <http.Request>[];
    final hub = HubClient(
      baseUrl: Uri.parse('https://hub.example.com'),
      token: 't',
      httpClient: MockClient((request) async {
        sent.add(request);
        return http.Response.bytes(utf8.encode(sample(reply)), 200);
      }),
    );
    return (presence: Presence(hub: () => hub, interval: const Duration(hours: 1)), sent: sent);
  }

  test('posts what plays and keeps the answer', () async {
    final (:presence, :sent) = make();
    presence.setWatching(watching);
    await presence.poke();
    expect(sent.single.url.path, HubPaths.presence);
    expect(jsonDecode(sent.single.body), {'watching': watching.toJson()});
    expect(presence.loaded, isTrue);
    expect(presence.watchingCount, 2);
    expect(presence.incoming.single.person.name, 'Carol');
    expect(presence.requestTo('1111222233334444')?.accepted, isTrue);
  });

  test('marks what plays private when sharing is off', () async {
    final (:presence, :sent) = make();
    presence.setWatching(watching);
    presence.share = false;
    await presence.poke();
    expect(jsonDecode(sent.last.body), {
      'watching': {...watching.toJson(), 'private': true},
    });
  });

  test('adds where the player is to each report', () async {
    final (:presence, :sent) = make();
    var position = 1000;
    presence.playback = () => PlaybackInfo(positionMs: position, durationMs: 60000, width: 1920, height: 1080);
    presence.setWatching(watching);
    await presence.poke();
    position = 21000;
    await presence.poke();
    final last = jsonDecode(sent.last.body)['watching'] as Map<String, dynamic>;
    expect(last['playback'], {'position_ms': 21000, 'duration_ms': 60000, 'width': 1920, 'height': 1080});
    expect(last.containsKey('private'), isFalse);
  });

  test('announces each new incoming and accepted request once', () async {
    final (:presence, sent: _) = make();
    final asked = <String>[];
    final accepted = <String?>[];
    presence.asked.listen((r) => asked.add(r.person.name));
    presence.accepted.listen((r) => accepted.add(r.room));
    await presence.poke();
    await presence.poke();
    await Future<void>.delayed(Duration.zero);
    expect(asked, ['Carol']);
    expect(accepted, ['K7MQ2X']);
  });

  test('a failed poll marks it offline without throwing', () async {
    final presence = Presence(
      hub: () => HubClient(
        baseUrl: Uri.parse('https://hub.example.com'),
        token: 't',
        httpClient: MockClient((_) async => http.Response('{"error":"down"}', 502)),
      ),
    );
    await presence.poke();
    expect(presence.offline, isTrue);
    expect(presence.loaded, isFalse);
  });

  test('answering sends the room', () async {
    final (:presence, :sent) = make();
    await presence.poke();
    await presence.answer(presence.incoming.single, accept: true, room: 'K7MQ2X');
    expect(sent.last.url.path, HubPaths.joinRequestsAnswer);
    expect(jsonDecode(sent.last.body), {'id': 'abcdef0123456789', 'accept': true, 'room': 'K7MQ2X'});
  });
}
