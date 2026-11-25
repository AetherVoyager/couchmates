import 'dart:convert';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Answers by full URL; anything else is a 404, and `down.example` fails.
http.Client server(Map<String, Object> routes, {List<String>? seen}) => MockClient((request) async {
  final url = request.url.toString();
  seen?.add(url);
  if (request.url.host == 'down.example') throw http.ClientException('offline');
  final body = routes[url];
  return body == null
      ? http.Response('{"detail":"Not Found"}', 404)
      : http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
});

const own = 'https://tg.example/stremio/tok';
const cine = 'https://cine.example';
const subs = 'https://subs.example';
const fallback = 'https://os.example';

Map<String, Object> routes() => {
  '$own/manifest.json': {
    'id': 'telegram',
    'name': 'Telegram',
    'resources': ['catalog', 'meta', 'stream'],
    'types': ['movie', 'series'],
    'catalogs': [
      {'type': 'movie', 'id': 'latest_movies', 'name': 'Popular'},
    ],
  },
  '$own/catalog/movie/latest_movies.json': {
    'metas': [
      {'id': 'tt1', 'type': 'movie', 'name': 'Mine'},
    ],
  },
  '$own/meta/movie/tt1.json': {
    'meta': {'id': 'tt1', 'type': 'movie', 'name': 'Mine (library)'},
  },
  '$own/stream/movie/tt1.json': {
    'streams': [
      {
        'name': '1080p',
        'url': 'https://tg.example/dl/1',
        'behaviorHints': {'bingeGroup': 'g'},
      },
      {'name': '❤ Support', 'externalUrl': 'https://donate.example'},
    ],
  },
  '$cine/manifest.json': {
    'id': 'cinemeta',
    'name': 'Cinemeta',
    'idPrefixes': ['tt'],
    'types': ['movie', 'series'],
    'resources': [
      'catalog',
      'meta',
      {
        'name': 'stream',
        'types': ['movie'],
      },
    ],
    'catalogs': [
      {'type': 'movie', 'id': 'top', 'name': 'Popular'},
      {'type': 'series', 'id': 'top', 'name': 'Popular'},
    ],
  },
  '$cine/catalog/movie/top.json': {
    'metas': [
      {'id': 'tt2', 'type': 'movie', 'name': 'Theirs'},
    ],
  },
  '$cine/meta/movie/tt2.json': {
    'meta': {'id': 'tt2', 'type': 'movie', 'name': 'Theirs (Cinemeta)'},
  },
  '$cine/stream/movie/tt1.json': {
    'streams': [
      {'name': 'Free copy', 'url': 'https://free.example/1.mp4'},
      {'name': 'Netflix', 'externalUrl': 'https://netflix.example/title/1'},
      {'name': 'Torrent', 'infoHash': 'abc'},
    ],
  },
  '$subs/manifest.json': {
    'id': 'subs',
    'name': 'Subs',
    'resources': ['subtitles'],
    'types': ['movie'],
    'catalogs': [],
  },
  '$subs/subtitles/movie/tt1.json': {
    'subtitles': [
      {'id': '1', 'url': 'https://s.example/1.srt', 'lang': 'eng'},
    ],
  },
  '$fallback/subtitles/movie/tt1.json': {
    'subtitles': [
      {'id': '9', 'url': 'https://os.example/9.srt', 'lang': 'eng'},
    ],
  },
};

AddonSet make({List<String> extras = const ['cine'], bool withOwn = true, List<String>? seen, Map<String, Object>? r}) {
  final http = server(r ?? routes(), seen: seen);
  final bases = {'cine': cine, 'subs': subs, 'down': 'https://down.example'};
  return AddonSet(
    primary: withOwn ? StremioClient(baseUrl: own, httpClient: http) : null,
    extras: [
      for (final e in extras)
        ExtraSource(
          id: e,
          name: e == 'cine' ? 'Cinemeta' : e,
          client: StremioClient(baseUrl: bases[e]!, httpClient: http, name: e, strictStreams: false),
        ),
    ],
    fallbackSubtitles: StremioClient(baseUrl: fallback, httpClient: http),
  );
}

void main() {
  test("rows: the catalog's first, then each add-on's, routed back to it", () async {
    final set = make(extras: ['cine', 'down']);
    final m = await set.manifest();
    expect(m.catalogs.map((c) => '${c.type}/${c.id}/${c.name}'), [
      'movie/latest_movies/Popular',
      'movie/cine~top/Popular (Cinemeta)',
      'series/cine~top/Popular',
    ]);
    final rows = await loadHomeRows(set);
    expect(rows.map((r) => r.items.single.name), ['Mine', 'Theirs']);
  });

  test('details: the library first, then add-ons that take the id', () async {
    final set = make();
    expect((await set.meta('movie', 'tt1'))?.name, 'Mine (library)');
    expect((await set.meta('movie', 'tt2'))?.name, 'Theirs (Cinemeta)');
    expect(await set.meta('movie', 'kitsu:1'), isNull);
  });

  test('streams are merged: playable ones, outside links, no torrents or donation links', () async {
    final set = make();
    final s = await set.streams('movie', 'tt1');
    expect(s.streams.map((x) => '${x.label} ${x.source}'), ['1080p null', 'Free copy cine']);
    expect(s.links.map((l) => '${l.name} ${l.url.host}'), ['Netflix netflix.example']);
    // Cinemeta's stream resource is for movies only.
    final seen = <String>[];
    await make(seen: seen).streams('series', 'tt1:1:1');
    expect(seen.where((u) => u.contains('/stream/')), ['$own/stream/series/tt1:1:1.json']);
  });

  test('watchable elsewhere only when an add-on answers with a stream the player can open', () async {
    final set = make(withOwn: false);
    expect(await set.streamsElsewhere('movie', 'tt1'), isTrue);
    // Cinemeta takes tt ids for movies but has nothing for this one.
    expect(await set.streamsElsewhere('movie', 'tt2'), isFalse);
    expect(await set.streamsElsewhere('series', 'tt1:1:1'), isFalse);
    final onlyLinks = routes()
      ..['$cine/stream/movie/tt3.json'] = {
        'streams': [
          {'name': 'Netflix', 'externalUrl': 'https://netflix.example/title/3'},
          {'name': 'Torrent', 'infoHash': 'abc'},
        ],
      };
    expect(await make(withOwn: false, r: onlyLinks).streamsElsewhere('movie', 'tt3'), isFalse);
  });

  test("the catalog's errors still surface when nothing else answers", () async {
    final r = routes()..remove('$own/manifest.json');
    await expectLater(make(extras: [], r: r).manifest(), throwsA(isA<StremioException>()));
    // With an add-on's rows, browsing still works.
    expect((await make(r: r).manifest()).catalogs, hasLength(2));
  });

  test('works with add-ons alone', () async {
    final set = make(withOwn: false);
    expect((await loadHomeRows(set)).single.items.single.name, 'Theirs');
    expect((await set.streams('movie', 'tt1')).streams.single.source, 'cine');
  });

  test('subtitles: from add-ons that offer them, else the fallback', () async {
    expect((await make(extras: ['cine', 'subs']).subtitles('movie', 'tt1')).map((s) => s.id), ['1']);
    expect((await make().subtitles('movie', 'tt1')).map((s) => s.id), ['9']);
  });
}
