import 'dart:convert';
import 'dart:io';

import 'package:couchmates/screens/subtitle_search_panel.dart';
import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

String contract(String name) => File('../../core/contract/$name').readAsStringSync();

http.Response json(String body) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json'});

const show = StremioMeta(id: 'tt0903747', type: 'series', name: 'Breaking Bad');
const ep = StremioVideo(id: 'tt0903747:1:2', title: 'E2', season: 1, episode: 2);
const playable = Playable(
  meta: show,
  video: ep,
  stream: StremioStream(url: 'https://tg.example.com/dl/1'),
);
const addon = [OnlineSubtitle(id: 'a', url: 'https://subs.example/a', language: 'eng')];

Future<List<SubtitleChoice>> showPanel(WidgetTester tester, HubSession session) async {
  final picked = <SubtitleChoice>[];
  final settings = AppSettings(MemorySettingsStore());
  await settings.load();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: settings),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 600,
              child: SubtitleSearchPanel(
                playable: playable,
                addon: addon,
                hash: Future.value('8e245d9679d31e12'),
                loaded: const {},
                onPick: (c) async {
                  picked.add(c);
                  return true;
                },
                onOpenFile: () async {},
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  testWidgets('without the Hub it offers the add-on list and says why', (tester) async {
    final session = HubSession(store: MemorySessionStore(), deviceName: 'Test PC');
    final picked = await showPanel(tester, session);
    expect(find.textContaining("free add-on's list"), findsOneWidget);
    expect(find.text('Subtitle 1'), findsOneWidget);
    expect(find.text('Add-on'), findsOneWidget);
    await tester.tap(find.text('Subtitle 1'));
    await tester.pumpAndSettle();
    expect(picked.single.url, 'https://subs.example/a');
  });

  testWidgets("with the Hub's OpenSubtitles it searches by episode and file hash", (tester) async {
    final searches = <Json>[];
    final session = HubSession(
      store: MemorySessionStore(),
      deviceName: 'Test PC',
      httpClient: () => MockClient((request) async {
        return switch (request.url.path) {
          HubPaths.login => json(contract('login_response.json')),
          HubPaths.config => json(contract('config_response.json')),
          HubPaths.subtitlesSearch => () {
            searches.add(jsonDecode(request.body) as Json);
            return json(contract('subtitle_search.json'));
          }(),
          _ => http.Response('{"error":"Not found"}', 404),
        };
      }),
    );
    await tester.runAsync(
      () => session.signIn(address: 'hub.example.com', username: 'alice', password: 'correct horse'),
    );
    final picked = await showPanel(tester, session);
    expect(searches.first, {
      'imdb': 'tt0903747',
      'season': 1,
      'episode': 2,
      'languages': ['en'],
      'hash': '8e245d9679d31e12',
    });
    expect(find.text('Matches your file'), findsOneWidget);
    expect(find.textContaining('48k downloads'), findsOneWidget);
    expect(find.textContaining("free add-on's list"), findsNothing);
    await tester.tap(find.text('Breaking.Bad.S01E02.720p.BluRay.x264-DEMAND'));
    await tester.pumpAndSettle();
    expect(picked.single.fileId, 1954677);
  });
}
