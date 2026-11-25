import 'dart:convert';

import 'package:couchmates/screens/requests_screen.dart';
import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'search_test.dart' show contract, json;

const _catalog = 'https://tg.example.com/stremio/abc123';

Json _req(
  String id,
  String name, {
  String status = RequestStatus.pending,
  List<String> by = const ['Bob'],
  bool mine = false,
  int? at,
}) => {
  'id': id,
  'kind': 'movie',
  'title_id': id,
  'name': name,
  'status': status,
  'requested_by': by,
  'mine': mine,
  'created_at': 1,
  'updated_at': at ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
};

/// A Hub with a few requests and a library that has a file for Arrived only.
http.Client _servers(List<http.Request> sent, List<Json> requests) => MockClient((request) async {
  sent.add(request);
  final url = request.url.toString();
  if (url.startsWith(_catalog)) {
    return switch (url.substring(_catalog.length)) {
      '/manifest.json' => json({
        'id': 'telegram',
        'name': 'telegram',
        'resources': ['catalog', 'meta', 'stream'],
        'types': ['movie'],
        'catalogs': <Object>[],
      }),
      '/meta/movie/tt9.json' => json({
        'meta': {'id': 'tt9', 'type': 'movie', 'name': 'Arrived'},
      }),
      '/stream/movie/tt9.json' => json({
        'streams': [
          {'name': '1080p', 'url': 'https://tg.example/dl/1/video.mkv'},
        ],
      }),
      // Marked added, but Telegram-Stremio only has its details, no file.
      '/meta/movie/tt8.json' => json({
        'meta': {'id': 'tt8', 'type': 'movie', 'name': 'Only details'},
      }),
      '/stream/movie/tt8.json' => json({'streams': <Object>[]}),
      _ => http.Response('{"detail":"Not Found"}', 404),
    };
  }
  return switch (request.url.path) {
    HubPaths.config => json({...jsonDecode(contract('config_response.json')) as Json, 'addons': <Object>[]}),
    HubPaths.requests when request.method == 'GET' => json({'requests': requests}),
    HubPaths.requests => json({
      ...requests.firstWhere((r) => r['title_id'] == (jsonDecode(request.body) as Json)['title_id']),
      'mine': true,
      'requested_by': ['Bob', 'Cat', 'alice'],
    }),
    HubPaths.requestsCancel => json({'ok': true}),
    _ => http.Response('{"error":"Not found"}', 404),
  };
});

Future<(HubSession, List<http.Request>)> _show(WidgetTester tester, List<Json> requests) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sent = <http.Request>[];
  final session = HubSession(
    store: MemorySessionStore(const StoredSession(hubUrl: 'https://hub.example.com', token: 't', username: 'alice')),
    deviceName: 'Test PC',
    httpClient: () => _servers(sent, requests),
  );
  await tester.runAsync(session.restore);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: AppSettings(MemorySettingsStore())),
      ],
      child: const MaterialApp(home: Scaffold(body: RequestsView())),
    ),
  );
  await _settle(tester);
  return (session, sent);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('my requests can be withdrawn; all requests come most wanted first and can be joined', (tester) async {
    final (_, sent) = await _show(tester, [
      _req('tt1', 'Mine', mine: true, by: ['alice']),
      _req('tt2', 'Liked', by: ['Bob', 'Cat']),
      _req('tt3', 'Loved', by: ['Bob', 'Cat', 'Dan']),
    ]);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Liked'), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'Withdraw'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(jsonDecode(sent.lastWhere((r) => r.url.path == HubPaths.requestsCancel).body), {'id': 'tt1'});

    await tester.tap(find.text('All requests'));
    await _settle(tester);
    final loved = tester.getTopLeft(find.text('Loved')).dy;
    final liked = tester.getTopLeft(find.text('Liked')).dy;
    expect(loved, lessThan(liked));
    expect(find.text('3 want it'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'I want it too').first);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    final joined = sent.lastWhere((r) => r.url.path == HubPaths.requests && r.method == 'POST');
    expect((jsonDecode(joined.body) as Json)['title_id'], 'tt3');
  });

  testWidgets('just added shows Play only for titles the library has a file for', (tester) async {
    await _show(tester, [
      _req('tt9', 'Arrived', status: RequestStatus.added, mine: true, by: ['alice']),
      _req('tt8', 'Only details', status: RequestStatus.added),
    ]);
    await tester.tap(find.text('Just added'));
    await _settle(tester);
    expect(find.text('Arrived'), findsWidgets);
    expect(find.text('Only details'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
  });

  test('airing dates read as days, weeks or months', () {
    final now = DateTime(2026, 11, 25, 12);
    expect(airsText(DateTime(2026, 11, 25, 20), now: now), 'Today');
    expect(airsText(DateTime(2026, 11, 26, 9), now: now), 'Tomorrow');
    expect(airsText(DateTime(2026, 11, 30), now: now), 'In 5 days');
    expect(airsText(DateTime(2026, 12, 16), now: now), 'In 3 weeks');
  });
}
