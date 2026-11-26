import 'dart:typed_data';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const movie = StremioMeta(id: 'tt0133093', type: 'movie', name: 'The Matrix');
const show = StremioMeta(id: 'tt0903747', type: 'series', name: 'Breaking Bad');
const ep = StremioVideo(id: 'tt0903747:1:2', title: 'E2', season: 1, episode: 2);
const stream = StremioStream(url: 'https://tg.example.com/dl/1', filename: 'The Matrix 1999.mkv');

Uint8List pattern(int length, int mul, int add) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * mul + add) % 256]);

void main() {
  test('asks by IMDb id, or by words when typed or when there is no id', () {
    final byId = subtitleRequestFor(
      const Playable(meta: show, video: ep, stream: stream),
      languages: ['en'],
    );
    expect(byId.toJson(), {
      'imdb': 'tt0903747',
      'season': 1,
      'episode': 2,
      'languages': ['en'],
    });
    final typed = subtitleRequestFor(
      const Playable(meta: movie, stream: stream),
      languages: [],
      query: ' Matrix ',
    );
    expect(typed.toJson(), {'query': 'Matrix', 'languages': <String>[]});
    const noId = StremioMeta(id: 'tg:42', type: 'movie', name: 'Home Video');
    expect(
      subtitleRequestFor(
        const Playable(meta: noId, stream: stream),
        languages: ['ml'],
      ).query,
      'Home Video',
    );
  });

  test('lists file matches first, then the Hub by popularity, then the add-on', () {
    const hub = SubtitleSearch(
      available: true,
      results: [
        SubtitleResult(fileId: 1, language: 'en', release: 'Popular', downloads: 900),
        SubtitleResult(fileId: 2, language: 'pt-BR', release: 'Brazil', downloads: 50),
        SubtitleResult(fileId: 3, language: 'en', release: 'Exact', downloads: 5, hashMatch: true),
      ],
    );
    final addon = [
      const OnlineSubtitle(id: 'a', url: 'https://subs.example/a', language: 'eng'),
      const OnlineSubtitle(id: 'b', url: 'https://subs.example/b', language: 'por'),
    ];
    final english = subtitleChoices(hub: hub, addon: addon, language: 'en');
    expect(english.map((c) => c.key), ['os:3', 'os:1', 'url:https://subs.example/a']);
    expect(english.last.label, 'Subtitle 1');
    expect(subtitleChoices(hub: hub, addon: addon, language: 'pt').map((c) => c.label), ['Brazil', 'Subtitle 2']);
    expect(subtitleChoices(hub: hub, addon: addon).length, 5);
    expect(subtitleChoices(addon: addon, language: 'en').single.fromHub, isFalse);
  });

  test("hashes like OpenSubtitles' reference", () {
    // The expected value comes from the reference algorithm in Python.
    expect(openSubtitlesHash(pattern(65536, 7, 3), pattern(65536, 13, 250), 5000000123), 'c040bf40ea45927b');
  });

  test('hashes a stream from two range requests', () async {
    const size = 200000;
    final file = pattern(size, 31, 9);
    final ranges = <String>[];
    final client = MockClient((request) async {
      final range = request.headers['range']!;
      ranges.add(range);
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      final from = int.parse(m[1]!), to = int.parse(m[2]!);
      return http.Response.bytes(file.sublist(from, to + 1), 206, headers: {'content-range': 'bytes $from-$to/$size'});
    });
    final hash = await fetchOpenSubtitlesHash(
      const Playable(meta: movie, stream: stream),
      client: client,
    );
    expect(ranges, ['bytes=0-65535', 'bytes=134464-199999']);
    expect(hash, openSubtitlesHash(file.sublist(0, 65536), file.sublist(size - 65536), size));
  });

  test('gives up when the server ignores ranges', () async {
    final client = MockClient((_) async => http.Response.bytes(Uint8List(70000), 200));
    expect(
      await fetchOpenSubtitlesHash(
        const Playable(meta: movie, stream: stream),
        client: client,
      ),
      isNull,
    );
  });
}
