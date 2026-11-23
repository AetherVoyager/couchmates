import 'dart:convert';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A Hub whose request list is whatever [requests] holds when asked.
http.Client hub(List<Map<String, Object?>> Function() requests) => MockClient((request) async {
  final body = switch (request.url.path) {
    HubPaths.config => {
      'user': {'id': 'u1', 'name': 'Alice', 'username': 'alice'},
      'device': {'id': 'd1', 'name': 'PC'},
      'addon': null,
      'voice': {'available': false},
    },
    HubPaths.requests => {'requests': requests()},
    HubPaths.trackers => {'trackers': <Object>[]},
    _ => {'ok': true},
  };
  return http.Response(jsonEncode(body), 200);
});

Map<String, Object?> req(String id, String status, {bool mine = true}) => {
  'id': id,
  'kind': 'movie',
  'title_id': 'tt$id',
  'name': 'Film $id',
  'status': status,
  'requested_by': ['Alice'],
  'mine': mine,
  'created_at': 1,
  'updated_at': 1,
};

void main() {
  test('answers are unseen until looked at, and arrivals are told once, even after a restart', () async {
    var list = [req('1', 'pending'), req('2', 'approved'), req('3', 'pending', mine: false)];
    final store = MemorySettingsStore();
    Future<(HubSession, AppSettings, RequestUpdates, List<String>)> start() async {
      final settings = AppSettings(store);
      await settings.load();
      final session = HubSession(
        store: MemorySessionStore(const StoredSession(hubUrl: 'https://hub.example', token: 't', username: 'alice')),
        deviceName: 'PC',
        httpClient: () => hub(() => list),
      );
      await session.restore();
      final updates = RequestUpdates(session: session, settings: settings);
      final told = <String>[];
      updates.arrivals.listen((r) => told.add(r.name));
      await updates.check();
      await Future<void>.delayed(Duration.zero);
      return (session, settings, updates, told);
    }

    var (session, _, updates, told) = await start();
    expect(updates.hasUnseen, isFalse, reason: 'the first run only remembers');
    expect(told, isEmpty);

    list = [req('1', 'added'), req('2', 'declined'), req('3', 'added', mine: false), req('4', 'pending')];
    await updates.check();
    await Future<void>.delayed(Duration.zero);
    expect(updates.unseen, {'1', '2'}, reason: "a friend's request and a new one of mine don't count");
    expect(told, ['Film 1']);

    await updates.check();
    await Future<void>.delayed(Duration.zero);
    expect(told, ['Film 1'], reason: 'told once');

    updates.dispose();
    session.dispose();
    (session, _, updates, told) = await start();
    expect(told, isEmpty, reason: 'not told again after a restart');
    expect(updates.unseen, {'1', '2'}, reason: 'still unseen until Search is opened');

    await updates.markSeen();
    expect(updates.hasUnseen, isFalse);
    await updates.check();
    expect(updates.hasUnseen, isFalse);
    updates.dispose();
    session.dispose();
  });
}
