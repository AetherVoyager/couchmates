import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const show = StremioMeta(id: 'tt0903747', type: 'series', name: 'Breaking Bad');
  const ep = StremioVideo(id: 'tt0903747:1:2', title: 'E2', season: 1, episode: 2);

  test('reports start, pause, resume and stop once each', () async {
    final sent = <ScrobbleRequest>[];
    final s = Scrobbler.forTitle((r) async => sent.add(r), meta: show, video: ep)!;
    await s.playing(true, 0.1);
    await s.playing(true, 0.2); // repeat: dropped
    await s.playing(false, 0.3);
    await s.playing(true, 0.3);
    await s.stopped(0.95);
    await s.playing(true, 0.95); // after stop: dropped
    expect(sent.map((r) => r.action), ['start', 'pause', 'start', 'stop']);
    expect(sent.last.progress, 95);
    expect([sent.first.kind, sent.first.season, sent.first.episode], ['episode', 1, 2]);
  });

  test('only IMDb titles scrobble', () {
    Future<void> send(ScrobbleRequest _) async {}
    expect(
      Scrobbler.forTitle(
        send,
        meta: const StremioMeta(id: 'tt1375666', type: 'movie', name: 'x'),
      ),
      isNotNull,
    );
    expect(
      Scrobbler.forTitle(
        send,
        meta: const StremioMeta(id: 'kitsu:1', type: 'series', name: 'x'),
      ),
      isNull,
    );
    expect(
      Scrobbler.forTitle(
        send,
        meta: show,
        video: const StremioVideo(id: 'tt0903747:x', title: 'x'),
      ),
      isNull,
      reason: 'episode without season and number',
    );
  });

  test('marks movies, episodes, seasons and shows', () {
    const movie = StremioMeta(id: 'tt1375666', type: 'movie', name: 'x');
    final m = Scrobbler.mark(movie, watched: true)!;
    expect([m.action, m.kind, m.season, m.episode], ['watched', 'movie', null, null]);
    final e = Scrobbler.mark(show, video: ep, watched: false)!;
    expect([e.action, e.kind, e.season, e.episode], ['unwatched', 'episode', 1, 2]);
    final s = Scrobbler.mark(show, season: 3, watched: true)!;
    expect([s.kind, s.season, s.episode], ['show', 3, null]);
    expect(Scrobbler.mark(show, watched: true)!.season, isNull);
    expect(Scrobbler.mark(const StremioMeta(id: 'kitsu:1', type: 'series', name: 'x'), watched: true), isNull);
  });
}
