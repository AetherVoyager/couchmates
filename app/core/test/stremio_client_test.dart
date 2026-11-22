import 'dart:convert';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/stremio.dart' as fx;

const base = 'https://tg.example.com/stremio/tok';

StremioClient clientFor(Map<String, Object> routes, {List<Uri>? seen}) => StremioClient(
  baseUrl: '$base/',
  httpClient: MockClient((request) async {
    seen?.add(request.url);
    final path = request.url.toString().substring(base.length);
    final body = routes[path];
    return body == null
        ? http.Response('not found', 404)
        : http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});
  }),
);

void main() {
  test('manifest: catalogs, extras and resources', () async {
    final m = await clientFor({'/manifest.json': fx.manifest}).manifest();
    expect(m.name, 'Telegram');
    expect(m.hasResource('stream'), isTrue);
    expect(m.catalogs.map((c) => '${c.type}/${c.id}'), ['movie/latest_movies', 'series/top_series']);
    expect(m.catalogs.first.genres, ['Action', 'Drama']);
    expect(m.catalogs.first.supports('search'), isFalse);
    expect(m.catalogs.last.supports('search'), isTrue);
    expect(m.catalogs.any((c) => c.needsInput), isFalse);
  });

  test('catalog paths carry extras and keep colons', () {
    expect(StremioClient.catalogPath('movie', 'latest_movies'), '/catalog/movie/latest_movies.json');
    expect(
      StremioClient.catalogPath('movie', 'top', extra: {'genre': 'Sci-Fi', 'skip': '15'}),
      '/catalog/movie/top/genre=Sci-Fi&skip=15.json',
    );
    expect(
      StremioClient.catalogPath('series', 'top', extra: {'search': 'bad guy'}),
      '/catalog/series/top/search=bad+guy.json',
    );
  });

  test('catalog items: text years and ratings, empty strings, no-id items dropped', () async {
    final seen = <Uri>[];
    final client = clientFor({
      '/catalog/movie/latest_movies/genre=Action&skip=15.json': {
        'metas': [
          fx.catalogItem,
          {...fx.catalogItem, 'id': ''},
        ],
      },
    }, seen: seen);
    final items = await client.catalog('movie', 'latest_movies', skip: 15, genre: 'Action');
    expect(items, hasLength(1));
    final m = items.single;
    expect(m.id, 'tt1375666');
    expect(m.year, 2010);
    expect(m.imdbRating, 8.8);
    expect(m.logo, isNull, reason: 'empty strings become null');
    expect(m.runtime, isNull);
    expect(m.genres, ['Action', 'Sci-Fi']);
  });

  test('series meta: year ranges, missing rating, seasons and episodes in order', () async {
    final meta = await clientFor({'/meta/series/tt0903747.json': fx.seriesMeta}).meta('series', 'tt0903747');
    expect(meta!.isSeries, isTrue);
    expect(meta.year, 2008);
    expect(meta.imdbRating, isNull);
    expect(meta.seasons, [1, 2, 0], reason: 'specials last');
    expect(meta.episodesOf(1).map((e) => e.title), ['Pilot', 'E02']);
    expect(meta.episodesOf(2).single.released, DateTime.utc(2009, 3, 8));
  });

  test('unknown item is null, not an error', () async {
    expect(await clientFor({}).meta('movie', 'tt0'), isNull);
  });

  test('streams keep playable ones and turn the rest into notices', () async {
    final result = await clientFor({
      '/stream/series/tt0903747:1:1.json': fx.streams,
    }).streams('series', 'tt0903747:1:1');
    final s = result.streams.single;
    expect(s.url, endsWith('video.mkv?via=cf'));
    expect(s.sizeBytes, 1610612736);
    expect(s.bingeGroup, 'telegram-stremio-1080p-cloudflare');
    expect(s.label, 'Telegram 1080p WEB-DL (Cloudflare)');
    expect(result.notices.map((n) => n.name), ['Limit Reached'], reason: 'donation link is not a notice');
  });

  test('an expired plan is a notice even though its link is https', () async {
    final result = await clientFor({'/stream/movie/tt1.json': fx.planExpired}).streams('movie', 'tt1');
    expect(result.streams, isEmpty);
    expect(result.notices.single.name, '🚫 Plan Expired');
  });

  test('search asks only catalogs that support it and merges without duplicates', () async {
    final seen = <Uri>[];
    final client = clientFor({
      '/manifest.json': fx.manifest,
      '/catalog/series/top_series/search=bad.json': {
        'metas': [
          {...fx.catalogItem, 'id': 'tt0903747', 'type': 'series'},
          {...fx.catalogItem, 'id': 'tt0903747', 'type': 'series'},
        ],
      },
    }, seen: seen);
    final results = await client.search('bad');
    expect(results.map((m) => m.id), ['tt0903747']);
    expect(seen.where((u) => u.path.contains('/catalog/')), hasLength(1));
  });

  test('server errors and unreachable servers', () async {
    final failing = StremioClient(baseUrl: base, httpClient: MockClient((_) async => http.Response('', 500)));
    await expectLater(failing.manifest(), throwsA(isA<StremioException>().having((e) => e.status, 'status', 500)));
    final down = StremioClient(baseUrl: base, httpClient: MockClient((_) async => throw Exception('down')));
    await expectLater(down.manifest(), throwsA(isA<StremioException>().having((e) => e.status, 'status', isNull)));
  });

  test('a missing manifest or a disabled catalog is an error with a reason, not an empty list', () async {
    final missing = StremioClient(
      baseUrl: base,
      httpClient: MockClient((_) async => http.Response('{"detail":"Not Found"}', 404)),
    );
    await expectLater(
      missing.manifest(),
      throwsA(isA<StremioException>().having((e) => e.message, 'message', contains("Telegram-Stremio address"))),
    );
    final disabled = StremioClient(
      baseUrl: base,
      httpClient: MockClient((_) async => http.Response('{"detail":"Catalog disabled"}', 404)),
    );
    await expectLater(
      disabled.catalog('movie', 'latest_movies'),
      throwsA(isA<StremioException>().having((e) => e.message, 'message', contains('Hide Catalog'))),
    );
    final rejected = StremioClient(
      baseUrl: base,
      httpClient: MockClient((_) async => http.Response('{"detail":"Invalid or expired API token"}', 401)),
    );
    await expectLater(
      rejected.manifest(),
      throwsA(isA<StremioException>().having((e) => e.message, 'message', contains("didn't accept"))),
    );
  });

  test('home rows explain a manifest without catalogs', () async {
    final client = clientFor({
      '/manifest.json': {...fx.manifest, 'catalogs': <Object>[]},
    });
    await expectLater(
      loadHomeRows(client),
      throwsA(isA<StremioException>().having((e) => e.message, 'message', contains('no catalogs'))),
    );
  });
}
