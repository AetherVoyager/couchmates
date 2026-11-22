import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/stremio.dart' as fx;

void main() {
  test('stream details split Telegram-Stremio lines into facts', () {
    const s = StremioStream(
      url: 'https://x/video.mkv',
      title: '📁 Inception.2010.1080p.mkv\n💾 1.5 GB\n🎥 x265 HDR 🔊 AAC 5.1\n🌐 English, Hindi',
    );
    final d = streamDetails(s);
    expect(d.map((x) => (x.kind, x.text)), [
      (StreamDetailKind.file, 'Inception.2010.1080p.mkv'),
      (StreamDetailKind.size, '1.5 GB'),
      (StreamDetailKind.video, 'x265 HDR'),
      (StreamDetailKind.audio, 'AAC 5.1'),
      (StreamDetailKind.language, 'English, Hindi'),
    ]);
  });

  test('size and file name come from hints when the text lacks them', () {
    const s = StremioStream(url: 'https://x', sizeBytes: 734003200, filename: 'a.mkv');
    final d = streamDetails(s);
    expect(d.first.text, 'a.mkv');
    expect(d.last.text, '700 MB');
  });

  test('catalog metas carry the TMDB id and writers', () {
    final m = StremioMeta.fromJson({
      ...fx.catalogItem,
      'writer': ['Christopher Nolan'],
    });
    expect(m.tmdbId, 27205);
    expect(m.writers, ['Christopher Nolan']);
    expect(StremioMeta.fromJson({...fx.catalogItem, 'moviedb_id': ''}).tmdbId, isNull);
  });

  test('Cinemeta trailers, country and release date', () {
    final m = StremioMeta.fromJson({
      ...fx.catalogItem,
      'trailers': [
        {'source': 'abc', 'type': 'Trailer'},
      ],
      'trailerStreams': [
        {'ytId': 'abc', 'title': 'Trailer'},
        {'ytId': 'def', 'title': 'Teaser'},
      ],
      'country': 'USA',
      'released': '2010-07-16T00:00:00.000Z',
    });
    expect(m.trailers, ['abc', 'def']);
    expect(m.country, 'USA');
    expect(m.released?.year, 2010);
  });

  test('watched marks and My list survive a reload', () async {
    final store = MemorySettingsStore();
    final show = StremioMeta.fromJson((fx.seriesMeta['meta'] as Map).cast<String, dynamic>());
    final progress = ProgressStore(store);
    await progress.setManyWatched(show, show.episodesOf(1), watched: true);
    await progress.setWatched(show, video: show.episodesOf(1).first, watched: false);
    final reloaded = ProgressStore(store);
    await reloaded.load();
    expect(reloaded.isWatched('tt0903747:1:1'), isFalse);
    expect(reloaded.isWatched('tt0903747:1:2'), isTrue);
    await reloaded.setManyWatched(show, show.episodesOf(1), watched: true);
    expect(reloaded.latestFor(show.id)?.videoId, 'tt0903747:1:2', reason: 'the last episode counts as last watched');

    final list = Watchlist(store);
    await list.toggle(show);
    await list.toggle(StremioMeta.fromJson(fx.catalogItem));
    final again = Watchlist(store);
    await again.load();
    expect(again.items.map((m) => m.id), ['tt1375666', 'tt0903747']);
    await again.toggle(show);
    expect(again.contains('tt0903747'), isFalse);
  });
}
