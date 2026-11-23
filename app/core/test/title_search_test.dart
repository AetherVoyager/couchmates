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
}
