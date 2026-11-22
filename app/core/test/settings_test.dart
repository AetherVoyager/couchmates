import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/stremio.dart' as fx;

const eng = TrackInfo(id: '1', language: 'eng');
const mal = TrackInfo(id: '2', language: 'mal');
const hin = TrackInfo(id: '3', language: 'hi');

void main() {
  group('AppSettings', () {
    test('defaults, saving, and falling back from bad stored values', () async {
      final store = MemorySettingsStore({'controls.seek_back': 7, 'appearance.theme': 'neon'});
      final settings = AppSettings(store);
      await settings.load();
      expect(settings.get(Settings.seekBack), 10, reason: '7 is not one of the choices');
      expect(settings.theme, ThemeChoice.dark);
      await settings.set(Settings.seekBack, 15);
      expect(store.values['controls.seek_back'], 15);
      await settings.set(Settings.seekBack, 10);
      expect(store.values.containsKey('controls.seek_back'), isFalse, reason: 'defaults are not stored');
      await settings.set(Settings.audioLanguages, 'ml, EN');
      expect(settings.audioLanguages, ['ml', 'en']);
    });
  });

  group('track choice', () {
    test('audio follows the preferred languages in order', () {
      expect(chooseAudio([eng, mal, hin], ['ml', 'en']), '2');
      expect(chooseAudio([eng, hin], ['ml', 'en']), '1');
      expect(chooseAudio([eng, hin], ['fr']), isNull, reason: 'no match keeps the default');
      expect(chooseAudio([eng], []), isNull);
    });

    test('subtitles: auto shows them only for audio you do not understand', () {
      const subs = [
        TrackInfo(id: 's1', language: 'eng'),
        TrackInfo(id: 's2', language: 'eng', forced: true),
        TrackInfo(id: 's3', language: 'mal'),
      ];
      String? pick(SubtitleMode mode, String audio, {List<String> sub = const [], List<String> aud = const ['en']}) =>
          chooseSubtitle(subs, mode: mode, preferredSubtitles: sub, preferredAudio: aud, audioLanguage: audio);

      expect(pick(SubtitleMode.auto, 'jpn'), 's1', reason: 'Japanese audio: English subtitles');
      expect(pick(SubtitleMode.auto, 'eng'), 's2', reason: 'English audio: only the forced track');
      expect(pick(SubtitleMode.auto, 'eng', sub: ['ml'], aud: ['en']), 's2');
      expect(pick(SubtitleMode.always, 'eng', sub: ['ml']), 's3');
      expect(pick(SubtitleMode.off, 'jpn'), 'no');
      expect(
        chooseSubtitle(
          [eng],
          mode: SubtitleMode.auto,
          preferredSubtitles: [],
          preferredAudio: ['en'],
          audioLanguage: 'en',
        ),
        'no',
        reason: 'understood audio and no forced track: subtitles off',
      );
    });
  });

  group('progress', () {
    final show = StremioMeta.fromJson((fx.seriesMeta['meta'] as Map).cast<String, dynamic>());

    test('next episode follows seasons, specials last', () {
      expect(show.nextAfter('tt0903747:1:1')?.id, 'tt0903747:1:2');
      expect(show.nextAfter('tt0903747:1:2')?.id, 'tt0903747:2:1');
      expect(show.nextAfter('tt0903747:2:1')?.id, 'tt0903747:0:1');
      expect(show.nextAfter('tt0903747:0:1'), isNull);
    });

    test('continue watching keeps unfinished titles, one per show, newest first', () async {
      final store = MemorySettingsStore();
      final progress = ProgressStore(store);
      WatchProgress p(String meta, String? video, int pos, int minute) => WatchProgress(
        metaId: meta,
        type: video == null ? 'movie' : 'series',
        name: meta,
        videoId: video,
        positionMs: pos,
        durationMs: 3600000,
        updatedAt: DateTime(2026, 1, 1, 0, minute),
      );
      await progress.save(p('movieA', null, 600000, 1));
      await progress.save(p('show', 'show:1:1', 1200000, 2));
      await progress.save(p('show', 'show:1:2', 900000, 3));
      await progress.save(p('movieB', null, 3500000, 4)); // finished
      await progress.save(p('movieC', null, 20000, 5)); // barely started
      expect(progress.continueWatching.map((e) => e.key), ['show:1:2', 'movieA']);

      final reloaded = ProgressStore(store);
      await reloaded.load();
      expect(reloaded.of('movieA')?.positionMs, 600000);
      expect(reloaded.latestFor('show')?.videoId, 'show:1:2');
    });
  });
}
