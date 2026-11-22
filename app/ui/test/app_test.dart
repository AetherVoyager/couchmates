import 'dart:convert';
import 'dart:io';

import 'package:couchmates/app.dart';
import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

String contract(String name) => File('../../core/contract/$name').readAsStringSync();

http.Response json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

const _manifest = {
  'id': 'telegram.media.x',
  'name': 'Telegram',
  'resources': ['catalog', 'meta', 'stream'],
  'types': ['movie', 'series'],
  'catalogs': [
    {
      'type': 'movie',
      'id': 'latest_movies',
      'name': 'Recently Added',
      'extra': [
        {'name': 'skip'},
      ],
    },
    {
      'type': 'series',
      'id': 'latest_series',
      'name': 'Recently Added',
      'extra': [
        {'name': 'skip'},
      ],
    },
  ],
};

/// A Hub and a catalog with one movie and one show.
http.Client fakeServers() => MockClient((request) async {
  final url = request.url.toString();
  const catalog = 'https://tg.example.com/stremio/abc123';
  if (url.startsWith(catalog)) {
    return switch (url.substring(catalog.length)) {
      '/manifest.json' => json(_manifest),
      '/catalog/movie/latest_movies.json' => json({
        'metas': [
          {'id': 'tt1375666', 'type': 'movie', 'name': 'Inception', 'year': '2010', 'poster': ''},
        ],
      }),
      '/catalog/series/latest_series.json' => json({
        'metas': [
          {'id': 'tt0903747', 'type': 'series', 'name': 'Breaking Bad', 'year': '2008-2013'},
        ],
      }),
      _ => http.Response('not found', 404),
    };
  }
  return switch (request.url.path) {
    HubPaths.login => http.Response(contract('login_response.json'), 200),
    HubPaths.config => http.Response(contract('config_response.json'), 200),
    _ => http.Response('{"error":"Wrong username or password."}', 401),
  };
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Couchmates',
      packageName: 'couchmates',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('signing in leads to home rows from the catalog', (tester) async {
    final session = HubSession(store: MemorySessionStore(), deviceName: 'Test PC', httpClient: fakeServers);
    await tester.pumpWidget(
      CouchmatesApp(
        session: session,
        settings: AppSettings(MemorySettingsStore()),
        progress: ProgressStore(MemorySettingsStore()),
        watchlist: Watchlist(MemorySettingsStore()),
      ),
    );
    await tester.runAsync(session.restore);
    await tester.pumpAndSettle();

    expect(find.text('Sign in with the details your admin sent you.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Enter the Hub address.'), findsOneWidget, reason: 'the form checks before calling the Hub');

    await tester.enterText(find.widgetWithText(TextFormField, 'Hub address'), 'hub.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'alice');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'correct horse');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      // Let the sign-in and the first catalog loads finish on real time.
      for (var i = 0; i < 20 && session.status != SessionStatus.signedIn; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(session.status, SessionStatus.signedIn);
    expect(find.text('Movies · Recently Added'), findsOneWidget);
    expect(find.text('Shows · Recently Added'), findsOneWidget);
    expect(find.text('Inception'), findsWidgets);
    expect(find.text('Breaking Bad'), findsWidgets);
  });

  testWidgets('a wrong password shows the Hub message', (tester) async {
    final session = HubSession(
      store: MemorySessionStore(),
      deviceName: 'Test PC',
      httpClient: () => MockClient((_) async => http.Response(contract('error_response.json'), 401)),
    );
    await tester.pumpWidget(
      CouchmatesApp(
        session: session,
        settings: AppSettings(MemorySettingsStore()),
        progress: ProgressStore(MemorySettingsStore()),
        watchlist: Watchlist(MemorySettingsStore()),
      ),
    );
    await tester.runAsync(session.restore);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Hub address'), 'hub.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'alice');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'nope');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Wrong username or password.'), findsOneWidget);
    expect(session.status, SessionStatus.signedOut);
  });
}
