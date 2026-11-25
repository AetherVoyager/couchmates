import 'dart:convert';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Answers by full URL; anything else is a 404, and `down.example` fails.
http.Client server(Map<String, Object> routes) => MockClient((request) async {
  if (request.url.host == 'down.example') throw http.ClientException('offline');
  final body = routes[request.url.toString()];
  return body == null
      ? http.Response('{"detail":"Not Found"}', 404)
      : http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
});

const lib = 'https://tg.example/stremio/tok';
const cine = 'https://cine.example';

Map<String, Object> manifest(String id) => {
  'id': id,
  'name': id,
  'resources': ['catalog', 'meta'],
  'types': ['movie', 'series'],
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

Map<String, Object> routes() => {
  '$lib/manifest.json': manifest('telegram'),
  '$lib/catalog/movie/top/search=matrix.json': {
    'metas': [
      {'id': 'tt0133093', 'type': 'movie', 'name': 'The Matrix', 'releaseInfo': '1999'},
      // A library without IMDb ids still matches by name and year.
      {'id': 'local-7', 'type': 'movie', 'name': 'The Matrix Reloaded', 'releaseInfo': '2003'},
    ],
  },
  '$cine/manifest.json': manifest('cinemeta'),
  '$cine/catalog/movie/top/search=matrix.json': {
    'metas': [
      {'id': 'tt0133093', 'type': 'movie', 'name': 'The Matrix', 'releaseInfo': '1999'},
      {'id': 'tt0234215', 'type': 'movie', 'name': 'The Matrix: Reloaded', 'releaseInfo': '2003'},
      {'id': 'tt10838180', 'type': 'movie', 'name': 'The Matrix Resurrections', 'releaseInfo': '2021'},
    ],
  },
  '$cine/meta/movie/tt10838180.json': {
    'meta': {'id': 'tt10838180', 'type': 'movie', 'name': 'The Matrix Resurrections', 'description': 'Neo again.'},
  },
};

void main() {
  test('library titles come first and marked; the rest are requestable, without repeats', () async {
    final http = server(routes());
    final search = TitleSearch(
      library: StremioClient(baseUrl: lib, httpClient: http),
      sources: [StremioClient(baseUrl: cine, httpClient: http)],
    );
    final hits = await search.search('matrix');
    expect(
      [for (final h in hits) (h.meta.id, h.inLibrary)],
      [('tt0133093', true), ('local-7', true), ('tt10838180', false)],
    );
    final details = await search.details(hits.last.meta);
    expect(details.description, 'Neo again.');
  });

  test('a library that fails still lets other sources answer; all failing is an error', () async {
    final http = server(routes());
    final down = TitleSearch(
      library: StremioClient(baseUrl: 'https://down.example', httpClient: http),
      sources: [StremioClient(baseUrl: cine, httpClient: http)],
    );
    expect((await down.search('matrix')).every((h) => !h.inLibrary), isTrue);
    final allDown = TitleSearch(
      library: StremioClient(baseUrl: 'https://down.example', httpClient: http),
      sources: [StremioClient(baseUrl: 'https://down.example/x', httpClient: http)],
    );
    expect(allDown.search('matrix'), throwsA(isA<StremioException>()));
  });

  test('a request carries the kind, id, year and an https poster only', () {
    final movie = requestFor(
      const StremioMeta(id: 'tt1', type: 'movie', name: 'A', releaseInfo: '1999', poster: 'http://x/p.jpg'),
    );
    expect(movie.toJson(), {'kind': 'movie', 'title_id': 'tt1', 'name': 'A', 'year': '1999'});
    final show = requestFor(const StremioMeta(id: 'tt2', type: 'series', name: 'B', poster: 'https://x/p.jpg'));
    expect(show.toJson(), {'kind': 'series', 'title_id': 'tt2', 'name': 'B', 'poster': 'https://x/p.jpg'});
  });

  group('opening a title', () {
    Map<String, Object> ep(int s, int e, {String? released}) => {
      'id': 'tt5:$s:$e',
      'title': 'Ep $e',
      'season': s,
      'episode': e,
      'released': ?released,
    };
    Map<String, Object> show({String id = 'tt5', required List<Map<String, Object>> videos}) => {
      'meta': {'id': id, 'type': 'series', 'name': 'The Show', 'releaseInfo': '2020', 'videos': videos},
    };
    TitleSearch searchOn(Map<String, Object> extra) {
      final http = server({...routes(), ...extra});
      return TitleSearch(
        library: StremioClient(baseUrl: lib, httpClient: http),
        sources: [StremioClient(baseUrl: cine, httpClient: http)],
      );
    }

    const item = StremioMeta(id: 'tt5', type: 'series', name: 'The Show', releaseInfo: '2020');
    // What Telegram-Stremio sends for a file it has, and for one it doesn't (only its donation link).
    final file = {
      'streams': [
        {
          'name': '1080p',
          'url': 'https://tg.example/dl/tok/1/video.mkv',
          'size_bytes': 5,
          'behaviorHints': {'bingeGroup': 'g'},
        },
      ],
    };
    final nothing = {
      'streams': [
        {'name': 'Support', 'externalUrl': 'https://donate.example'},
      ],
    };

    test('a show the library has lists the released episodes it lacks', () async {
      final search = searchOn({
        '$lib/meta/series/tt5.json': show(videos: [ep(1, 1), ep(1, 3)]),
        '$lib/stream/series/tt5:1:1.json': file,
        '$cine/meta/series/tt5.json': show(
          videos: [
            ep(1, 1),
            ep(1, 2),
            ep(1, 3),
            ep(0, 1),
            ep(2, 1, released: '2020-03-01T00:00:00Z'),
            ep(2, 2, released: '2999-01-01T00:00:00Z'),
          ],
        ),
      });
      final found = await search.lookUp(item);
      expect(found.inLibrary && found.playable, isTrue);
      expect([for (final v in found.missing()) '${v.season}:${v.episode}'], ['1:2', '2:1']);
    });

    test("a title the library doesn't have comes from the other catalogs", () async {
      final search = searchOn({
        '$lib/meta/series/tt5.json': {'meta': null},
        '$cine/meta/series/tt5.json': show(videos: [ep(1, 1), ep(1, 2)]),
      });
      final found = await search.lookUp(item);
      expect(found.inLibrary || found.playable, isFalse);
      expect(found.full?.videos.length, 2);
      expect(found.missing(), isEmpty);
    });

    test("the library's details for a title it has no file for don't make it the library's", () async {
      // Telegram-Stremio answers /meta/ for any title, with TMDB's or Cinemeta's details.
      final search = searchOn({
        '$lib/meta/series/tt5.json': show(videos: [ep(1, 1), ep(1, 2)]),
        '$lib/stream/series/tt5:1:1.json': nothing,
        '$cine/meta/series/tt5.json': show(videos: [ep(1, 1), ep(1, 2)]),
        '$lib/meta/movie/tt7.json': {
          'meta': {'id': 'tt7', 'type': 'movie', 'name': 'Elsewhere', 'videos': <Object>[]},
        },
        '$lib/stream/movie/tt7.json': nothing,
        '$lib/meta/movie/tt8.json': {'meta': <String, Object>{}},
        '$lib/meta/movie/tt9.json': {
          'meta': {'id': 'tt9', 'type': 'movie', 'name': 'Here'},
        },
        '$lib/stream/movie/tt9.json': file,
      });
      final series = await search.lookUp(item);
      expect(series.inLibrary || series.playable, isFalse);
      expect(series.full?.videos.length, 2);
      const movie = StremioMeta(id: 'tt7', type: 'movie', name: 'Elsewhere');
      expect((await search.lookUp(movie)).playable, isFalse);
      // A title the token can't see comes back as an empty meta.
      expect((await search.lookUp(const StremioMeta(id: 'tt8', type: 'movie', name: 'Hidden'))).playable, isFalse);
      expect((await search.lookUp(const StremioMeta(id: 'tt9', type: 'movie', name: 'Here'))).inLibrary, isTrue);
    });

    test('a library without IMDb ids is matched by name and year', () async {
      final search = searchOn({
        '$lib/catalog/movie/top/search=The+Show.json': {
          'metas': [
            {'id': 'local-5', 'type': 'series', 'name': 'The Show', 'releaseInfo': '2020'},
          ],
        },
        '$lib/meta/series/local-5.json': show(id: 'local-5', videos: [ep(1, 1)]),
        '$cine/meta/series/tt5.json': show(videos: [ep(1, 1), ep(1, 2)]),
      });
      final found = await search.lookUp(item);
      expect(found.inLibrary, isTrue);
      expect(found.meta.id, 'local-5');
    });

    test('episode requests carry the numbers and name', () {
      const v = StremioVideo(id: 'tt5:1:2', title: ' Two ', season: 1, episode: 2);
      expect(requestFor(item, video: v).toJson(), {
        'kind': 'series',
        'title_id': 'tt5',
        'name': 'The Show',
        'year': '2020',
        'season': 1,
        'episode': 2,
        'episode_title': 'Two',
      });
      expect(episodesRequestFor(item, [v]).toJson()['episodes'], [
        {'season': 1, 'episode': 2, 'title': 'Two'},
      ]);
    });
  });

  test('requests group by title, episodes in order, the most pressing status first', () {
    MediaRequest r(String id, String title, String status, {int? s, int? e, bool mine = false}) => MediaRequest(
      id: id,
      kind: s == null ? 'movie' : 'series',
      titleId: title,
      name: title,
      season: s,
      episode: e,
      status: status,
      mine: mine,
      createdAt: 1,
      updatedAt: 1,
    );
    final groups = groupRequests([
      r('a', 'tt5', RequestStatus.added, s: 2, e: 1),
      r('b', 'tt1', RequestStatus.pending),
      r('c', 'tt5', RequestStatus.approved, s: 1, e: 3, mine: true),
      r('d', 'tt5', RequestStatus.added, s: 1, e: 2),
    ]);
    expect([for (final g in groups) g.first.titleId], ['tt5', 'tt1']);
    expect(groups.first.episodesText, 'S1 E2, E3 · S2 E1');
    expect(groups.first.status, RequestStatus.approved);
    expect(groups.first.mine, isTrue);
    expect(groups.last.episodesText, isNull);
  });

  test('clearing hides finished requests up to that time, never waiting ones', () {
    MediaRequest r(String id, String title, String status, int at) => MediaRequest(
      id: id,
      kind: 'movie',
      titleId: title,
      name: title,
      status: status,
      mine: true,
      createdAt: 1,
      updatedAt: at,
    );
    final groups = groupRequests([
      r('a', 'tt1', RequestStatus.added, 100),
      r('b', 'tt2', RequestStatus.declined, 300),
      r('c', 'tt3', RequestStatus.pending, 50),
      r('d', 'tt4', RequestStatus.approved, 50),
    ]);
    expect([for (final g in withoutCleared(groups, 0)) g.first.titleId], ['tt1', 'tt2', 'tt3', 'tt4']);
    // tt2 was answered after the clear, so it shows again.
    expect([for (final g in withoutCleared(groups, 200)) g.first.titleId], ['tt2', 'tt3', 'tt4']);
    expect([for (final g in withoutCleared(groups, 300)) g.first.titleId], ['tt3', 'tt4']);
  });
}
