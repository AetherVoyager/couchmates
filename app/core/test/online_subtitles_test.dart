import 'dart:convert';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const movie = StremioMeta(id: 'tt0133093', type: 'movie', name: 'The Matrix');
const show = StremioMeta(id: 'tt0903747', type: 'series', name: 'Breaking Bad');
const ep = StremioVideo(id: 'tt0903747:1:2', title: 'E2', season: 1, episode: 2);
const stream = StremioStream(url: 'https://tg.example.com/dl/1', filename: 'The Matrix 1999.mkv', sizeBytes: 1234);

OnlineSubtitle sub(String id, String lang) => OnlineSubtitle(id: id, url: 'https://subs.example/$id', language: lang);

Future<AppSettings> settings(Map<String, Object> values) async {
  final s = AppSettings(MemorySettingsStore(values));
  await s.load();
  return s;
}

void main() {
  test('looks titles up by IMDb id, episodes as tt:season:episode', () {
    expect(subtitleLookup(const Playable(meta: movie, stream: stream)), (type: 'movie', id: 'tt0133093'));
    expect(subtitleLookup(const Playable(meta: show, video: ep, stream: stream)), (
      type: 'series',
      id: 'tt0903747:1:2',
    ));
    const tmdbOnly = StremioMeta(id: 'tmdb:603', type: 'movie', name: 'x');
    expect(subtitleLookup(const Playable(meta: tmdbOnly, stream: stream)), isNull);
    const noNumber = StremioVideo(id: 'tt0903747:x', title: 'x');
    expect(subtitleLookup(const Playable(meta: show, video: noNumber, stream: stream)), isNull);
  });

  test('fetches the list with the file name and size, dropping unusable entries', () async {
    final seen = <Uri>[];
    final client = StremioClient(
      baseUrl: openSubtitlesAddon,
      httpClient: MockClient((request) async {
        seen.add(request.url);
        return http.Response(
          jsonEncode({
            'subtitles': [
              {'id': '1', 'url': 'https://subs.example/1', 'lang': 'eng', 'subtitleFileName': 'matrix.srt'},
              {'id': 2, 'url': 'https://subs.example/2', 'lang': 'ger'},
              {'id': '3', 'url': 'ftp://nope', 'lang': 'eng'},
              {'id': '4', 'lang': 'eng'},
            ],
          }),
          200,
        );
      }),
    );
    final subs = await fetchOnlineSubtitles(client, const Playable(meta: movie, stream: stream));
    expect(
      seen.single.toString(),
      '$openSubtitlesAddon/subtitles/movie/tt0133093/filename=The+Matrix+1999.mkv&videoSize=1234.json',
    );
    expect(subs.map((s) => '${s.id} ${s.language} ${s.fileName}'), ['1 eng matrix.srt', '2 ger null']);
  });

  test('an unreachable addon or unknown title is just no subtitles', () async {
    final down = StremioClient(baseUrl: openSubtitlesAddon, httpClient: MockClient((_) async => throw 'offline'));
    expect(await fetchOnlineSubtitles(down, const Playable(meta: movie, stream: stream)), isEmpty);
    final missing = StremioClient(
      baseUrl: openSubtitlesAddon,
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    expect(await fetchOnlineSubtitles(missing, const Playable(meta: show, video: ep, stream: stream)), isEmpty);
  });

  test('offers a few per preferred language, else any', () {
    final all = [sub('a', 'spa'), sub('b', 'eng'), sub('c', 'eng'), sub('d', 'mal'), sub('e', 'eng'), sub('f', 'eng')];
    expect(pickOnlineSubtitles(all, ['ml', 'en']).map((s) => s.id), ['d', 'b', 'c', 'e']);
    expect(pickOnlineSubtitles(all, ['ja'], fallback: 2).map((s) => s.id), ['a', 'b']);
    expect(normalizeLanguage('pob'), 'pt');
  });

  test('menu languages: subtitle ones, else audio ones, else English', () async {
    expect(onlineSubtitleLanguages(await settings({})), ['en']);
    expect(onlineSubtitleLanguages(await settings({'playback.audio_languages': 'ml, en'})), ['ml', 'en']);
    expect(
      onlineSubtitleLanguages(await settings({'playback.audio_languages': 'ml', 'playback.subtitle_languages': 'eng'})),
      ['en'],
    );
  });

  test('loads one at start only when the file lacks subtitles the settings want', () async {
    const english = TrackInfo(id: '1', language: 'eng');
    const forcedEnglish = TrackInfo(id: '2', language: 'eng', forced: true);
    final auto = await settings({'playback.audio_languages': 'en', 'playback.subtitle_languages': 'en'});
    // Japanese audio, no English subtitles in the file: fetch English.
    expect(autoOnlineLanguage(const [], auto, audioLanguage: 'jpn'), 'en');
    expect(autoOnlineLanguage(const [forcedEnglish], auto, audioLanguage: 'jpn'), 'en');
    // The file has them: its own track wins.
    expect(autoOnlineLanguage(const [english], auto, audioLanguage: 'jpn'), isNull);
    // English audio: no subtitles needed.
    expect(autoOnlineLanguage(const [], auto, audioLanguage: 'eng'), isNull);

    final always = await settings({'playback.subtitle_languages': 'ml', 'playback.subtitle_mode': 'always'});
    expect(autoOnlineLanguage(const [english], always, audioLanguage: 'eng'), 'ml');
    final never = await settings({'playback.subtitle_languages': 'ml', 'playback.subtitle_mode': 'off'});
    expect(autoOnlineLanguage(const [], never, audioLanguage: 'jpn'), isNull);
    // No languages set: nothing to look for.
    expect(autoOnlineLanguage(const [], await settings({}), audioLanguage: 'jpn'), isNull);
  });
}
