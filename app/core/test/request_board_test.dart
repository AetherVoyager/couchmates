import 'dart:convert';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Client server(Map<String, Object> routes) => MockClient((request) async {
  final body = routes[request.url.toString()];
  return body == null
      ? http.Response('{"detail":"Not Found"}', 404)
      : http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
});

const lib = 'https://tg.example/stremio/tok';
const cine = 'https://cine.example';

MediaRequest req(
  String id, {
  String kind = 'movie',
  String? title,
  String status = RequestStatus.pending,
  List<String> by = const ['Bob'],
  bool mine = false,
  int at = 100,
  int? season,
  int? episode,
}) => MediaRequest(
  id: id,
  kind: kind,
  titleId: title ?? id,
  name: 'Title ${title ?? id}',
  season: season,
  episode: episode,
  status: status,
  requestedBy: by,
  mine: mine,
  createdAt: 1,
  updatedAt: at,
);

Map<String, Object> ep(String show, int s, int e, String released) => {
  'id': '$show:$s:$e',
  'title': 'Episode $e',
  'season': s,
  'episode': e,
  'released': released,
};

const file = {
  'streams': [
    {'name': '1080p', 'url': 'https://tg.example/dl/1/video.mkv'},
  ],
};

void main() {
  test('waiting requests come most wanted first, answered ones after', () {
    final groups = groupRequests([
      req('a', at: 300),
      req('b', by: ['Bob', 'Cat', 'Dan'], at: 100),
      req('c', status: RequestStatus.added, by: ['Bob', 'Cat', 'Dan', 'Eve'], at: 400),
      req('d', by: ['Bob', 'Cat'], at: 200),
      // Episodes of one show count everyone who asked for any of them.
      req('s1', kind: 'series', title: 'show', season: 1, episode: 1, by: ['Bob']),
      req('s2', kind: 'series', title: 'show', season: 1, episode: 2, by: ['Cat', 'Dan']),
    ]);
    expect([for (final g in mostWanted(groups)) g.first.titleId], ['b', 'show', 'd', 'a', 'c']);
  });

  test('joinable and withdrawable requests', () {
    final g = groupRequests([
      req('s1', kind: 'series', title: 'show', season: 1, episode: 1, mine: true),
      req('s2', kind: 'series', title: 'show', season: 1, episode: 2),
      req('s3', kind: 'series', title: 'show', season: 1, episode: 3, status: RequestStatus.added),
      // A whole-show request from an older app can't be joined from the list.
      req('w', kind: 'series'),
    ]);
    final show = g.firstWhere((x) => x.first.titleId == 'show');
    expect(show.joinable.map((r) => r.id), ['s2']);
    expect(show.joinableEpisodes.single.id, 'show:1:2');
    expect(show.withdrawable.map((r) => r.id), ['s1']);
    expect(g.firstWhere((x) => x.first.titleId == 'w').joinable, isEmpty);
  });

  test('just added lists only requested titles the library has a file for', () async {
    final http = server({
      '$lib/manifest.json': {
        'id': 'tg',
        'name': 'tg',
        'resources': ['meta', 'stream'],
        'types': ['movie', 'series'],
      },
      // Has a file.
      '$lib/meta/movie/m1.json': {
        'meta': {'id': 'm1', 'type': 'movie', 'name': 'Here'},
      },
      '$lib/stream/movie/m1.json': file,
      // Telegram-Stremio answers /meta/ for titles it doesn't have, with no file behind them.
      '$lib/meta/movie/m2.json': {
        'meta': {'id': 'm2', 'type': 'movie', 'name': 'Not here'},
      },
      '$lib/stream/movie/m2.json': {'streams': <Object>[]},
      // A show with episode 1 only: episode 2 was marked added but has no file yet.
      '$lib/meta/series/show.json': {
        'meta': {
          'id': 'show',
          'type': 'series',
          'name': 'Show',
          'videos': [ep('show', 1, 1, '2020-01-01T00:00:00Z'), ep('show', 1, 2, '2020-01-08T00:00:00Z')],
        },
      },
      '$lib/stream/series/show:1:1.json': file,
      '$lib/stream/series/show:1:2.json': {'streams': <Object>[]},
    });
    final search = TitleSearch(
      library: StremioClient(baseUrl: lib, httpClient: http),
    );
    final groups = groupRequests([
      req('m1', status: RequestStatus.added, at: 1000),
      req('m2', status: RequestStatus.added, at: 1000),
      req('old', status: RequestStatus.added, at: 1),
      req('m3', at: 1000),
      req('e1', kind: 'series', title: 'show', season: 1, episode: 1, status: RequestStatus.added, at: 900, mine: true),
      req('e2', kind: 'series', title: 'show', season: 1, episode: 2, status: RequestStatus.added, at: 900, mine: true),
    ]);
    final found = await findArrived(search, groups, nowSeconds: 1000, within: const Duration(seconds: 500));
    // The user's own first.
    expect([for (final a in found) a.meta.id], ['show', 'm1']);
    expect(found.first.episodes.map((v) => v.id), ['show:1:1']);
    expect(found.first.video?.id, 'show:1:1');
    expect(found.last.video, isNull);
  });

  test('coming soon finds the next episode of requested shows', () async {
    final now = DateTime.utc(2026, 11, 25);
    final http = server({
      '$cine/manifest.json': {
        'id': 'c',
        'name': 'c',
        'resources': ['meta'],
        'types': ['series'],
      },
      '$cine/meta/series/a.json': {
        'meta': {
          'id': 'a',
          'type': 'series',
          'name': 'A',
          'videos': [
            ep('a', 1, 1, '2026-01-01T00:00:00Z'),
            ep('a', 1, 3, '2026-12-20T00:00:00Z'),
            ep('a', 1, 2, '2026-12-10T00:00:00Z'),
            // Specials don't count.
            ep('a', 0, 1, '2026-11-30T00:00:00Z'),
          ],
        },
      },
      '$cine/meta/series/b.json': {
        'meta': {
          'id': 'b',
          'type': 'series',
          'name': 'B',
          'videos': [ep('b', 2, 1, '2026-12-01T00:00:00Z')],
        },
      },
      // Nothing announced.
      '$cine/meta/series/c.json': {
        'meta': {
          'id': 'c',
          'type': 'series',
          'name': 'C',
          'videos': [ep('c', 1, 1, '2020-01-01T00:00:00Z')],
        },
      },
      '$cine/meta/series/d.json': {
        'meta': {
          'id': 'd',
          'type': 'series',
          'name': 'D',
          'videos': [ep('d', 1, 1, '2026-12-01T00:00:00Z')],
        },
      },
    });
    final search = TitleSearch(
      sources: [StremioClient(baseUrl: cine, httpClient: http)],
    );
    final groups = groupRequests([
      req('a1', kind: 'series', title: 'a', season: 1, episode: 1),
      req('b1', kind: 'series', title: 'b', season: 1, episode: 1, status: RequestStatus.added),
      req('c1', kind: 'series', title: 'c', season: 1, episode: 1),
      // Declined shows are left out.
      req('d1', kind: 'series', title: 'd', season: 1, episode: 1, status: RequestStatus.declined),
      req('movie'),
    ]);
    final soon = await findUpcoming(search, groups, now: now);
    expect([for (final u in soon) u.video.id], ['b:2:1', 'a:1:2']);
  });
}
