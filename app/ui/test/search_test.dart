import 'dart:convert';
import 'dart:io';

import 'package:couchmates/screens/search_screen.dart';
import 'package:couchmates/widgets/poster.dart';
import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

String contract(String name) => File('../../core/contract/$name').readAsStringSync();

http.Response json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

const _catalog = 'https://tg.example.com/stremio/abc123';
const _cinemeta = 'https://v3-cinemeta.strem.io';

Map<String, Object> _manifest(String id) => {
  'id': id,
  'name': id,
  'resources': ['catalog', 'meta'],
  'types': ['movie'],
  'catalogs': [
    {
      'type': 'movie',
      'id': 'top',
      'name': 'Top',
      'extra': [
        {'name': 'search'},
      ],
    },
  ],
};

/// A Hub with no requests yet, a library with Inception, and Cinemeta, which also knows Interstellar.
http.Client fakeServers(List<http.Request> sent) => MockClient((request) async {
  sent.add(request);
  final url = request.url.toString();
  if (url.startsWith(_catalog)) {
    return switch (url.substring(_catalog.length)) {
      '/manifest.json' => json(_manifest('telegram')),
      '/catalog/movie/top/search=in.json' => json({
        'metas': [
          {'id': 'tt1375666', 'type': 'movie', 'name': 'Inception', 'releaseInfo': '2010'},
        ],
      }),
      _ => http.Response('{"detail":"Not Found"}', 404),
    };
  }
  if (url.startsWith(_cinemeta)) {
    return switch (url.substring(_cinemeta.length)) {
      '/manifest.json' => json(_manifest('cinemeta')),
      '/catalog/movie/top/search=in.json' => json({
        'metas': [
          {'id': 'tt1375666', 'type': 'movie', 'name': 'Inception', 'releaseInfo': '2010'},
          {
            'id': 'tt0816692',
            'type': 'movie',
            'name': 'Interstellar',
            'releaseInfo': '2014',
            'description': 'Space.',
            'poster': 'https://img.example/i.jpg',
          },
        ],
      }),
      _ => http.Response('{"detail":"Not Found"}', 404),
    };
  }
  return switch (request.url.path) {
    HubPaths.config => json({...jsonDecode(contract('config_response.json')) as Json, 'addons': <Object>[]}),
    HubPaths.requests when request.method == 'GET' => json({'requests': <Object>[]}),
    HubPaths.requests => json({
      'id': 'r1',
      ...jsonDecode(request.body) as Json,
      'status': 'pending',
      'requested_by': ['Alice'],
      'mine': true,
      'created_at': 1,
      'updated_at': 1,
    }),
    _ => http.Response('{"error":"Not found"}', 404),
  };
});

void main() {
  testWidgets('search marks library titles and requests the rest', (tester) async {
    final sent = <http.Request>[];
    final session = HubSession(
      store: MemorySessionStore(const StoredSession(hubUrl: 'https://hub.example.com', token: 't', username: 'alice')),
      deviceName: 'Test PC',
      httpClient: () => fakeServers(sent),
    );
    await tester.runAsync(session.restore);
    expect(session.titleSearch, isNotNull);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: session),
          ChangeNotifierProvider.value(value: AppSettings(MemorySettingsStore())),
        ],
        child: const MaterialApp(home: Scaffold(body: SearchView())),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(session.requestsLoaded, isTrue);
    expect(find.textContaining('you can request it'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'in');
    await tester.runAsync(() async {
      await tester.pump(const Duration(milliseconds: 450));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    // The library's Inception only, not a second one from Cinemeta.
    expect(find.byType(PosterCard), findsNWidgets(2));
    expect(find.text('Interstellar'), findsWidgets);
    expect(find.text('In library'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Request'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Request'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    final asked = sent.lastWhere((r) => r.url.path == HubPaths.requests && r.method == 'POST');
    expect(jsonDecode(asked.body), {
      'kind': 'movie',
      'title_id': 'tt0816692',
      'name': 'Interstellar',
      'year': '2014',
      'poster': 'https://img.example/i.jpg',
    });
    expect(find.text('Requested'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Request'), findsNothing);
  });
}
