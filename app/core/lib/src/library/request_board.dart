import 'dart:async';

import '../hub/api.dart';
import '../stremio/models.dart';
import 'title_search.dart';

// What the Requests tab shows: requests by how much they're wanted, requested titles that reached the library,
// and the next episodes of requested shows.

extension RequestGroupWanted on RequestGroup {
  /// Everyone who asked for any part of it, first askers first.
  List<String> get askers => {for (final r in requests) ...r.requestedBy}.toList();

  /// Whether any of it still waits for the admin.
  bool get waiting => requests.any((r) => r.open);

  /// Its requests this user can join: waiting ones they aren't on. Whole-show requests from older apps can't be
  /// joined; their episodes are asked for on the show's page.
  List<MediaRequest> get joinable => [
    for (final r in requests)
      if (r.open && !r.mine && (r.kind == 'movie' || r.isEpisode)) r,
  ];

  /// This user's requests in it that can still be withdrawn.
  List<MediaRequest> get withdrawable => [
    for (final r in requests)
      if (r.open && r.mine) r,
  ];

  /// The episodes of its [joinable] requests, to ask for them too.
  List<StremioVideo> get joinableEpisodes => [
    for (final r in joinable)
      if (r.isEpisode)
        StremioVideo(
          id: '${r.titleId}:${r.season}:${r.episode}',
          title: r.episodeTitle ?? '',
          season: r.season,
          episode: r.episode,
        ),
  ];
}

/// [groups] most wanted first: waiting ones by how many people asked, then the newest change; answered ones
/// after them, newest first.
List<RequestGroup> mostWanted(List<RequestGroup> groups) {
  final out = [...groups];
  out.sort((a, b) {
    if (a.waiting != b.waiting) return a.waiting ? -1 : 1;
    if (a.waiting) {
      final n = b.askers.length.compareTo(a.askers.length);
      if (n != 0) return n;
    }
    return b.changedAt.compareTo(a.changedAt);
  });
  return out;
}

/// A requested title that the library now plays: the library's details, and for a show, the requested episodes
/// that have a file ([episodes], in order).
class ArrivedTitle {
  const ArrivedTitle({required this.group, required this.meta, this.episodes = const []});

  final RequestGroup group;

  /// The library's details, to open and play it.
  final StremioMeta meta;

  /// For a show: the requested episodes the library has a file for.
  final List<StremioVideo> episodes;

  /// What Play starts: the first requested episode for a show, the movie otherwise.
  StremioVideo? get video => episodes.firstOrNull;

  /// When the request was answered (seconds, the Hub's clock).
  int get addedAt => [
    for (final r in group.requests)
      if (r.status == RequestStatus.added) r.updatedAt,
  ].fold(0, (a, b) => a > b ? a : b);
}

/// The requested titles marked Added in the last [within] (by the Hub's time [nowSeconds]) that the library
/// really has a file for, the user's own first and then the newest. At most [max] are checked, so a long list
/// doesn't send dozens of lookups. A title whose lookup fails is left out.
Future<List<ArrivedTitle>> findArrived(
  TitleSearch search,
  List<RequestGroup> groups, {
  required int nowSeconds,
  Duration within = const Duration(days: 30),
  int max = 24,
}) async {
  final since = nowSeconds - within.inSeconds;
  final candidates = [
    for (final g in groups)
      if (g.requests.any((r) => r.status == RequestStatus.added && r.updatedAt >= since)) g,
  ];
  int added(RequestGroup g) => ArrivedTitle(group: g, meta: g.meta).addedAt;
  candidates.sort((a, b) {
    if (a.mine != b.mine) return a.mine ? -1 : 1;
    return added(b).compareTo(added(a));
  });
  final checks = [for (final g in candidates.take(max)) _arrived(search, g)];
  return [for (final a in await Future.wait(checks)) ?a];
}

Future<ArrivedTitle?> _arrived(TitleSearch search, RequestGroup group) async {
  try {
    final found = await search.lookUp(group.meta);
    if (!found.inLibrary) return null;
    if (!group.isEpisodes) return ArrivedTitle(group: group, meta: found.meta);
    final wanted = {
      for (final r in group.requests)
        if (r.status == RequestStatus.added && r.isEpisode) '${r.season}:${r.episode}',
    };
    final videos = [
      for (final v in found.meta.videos)
        if (wanted.contains('${v.season}:${v.episode}')) v,
    ];
    final has = await Future.wait([for (final v in videos) search.libraryHasFile(found.meta, video: v)]);
    final episodes = [
      for (final (i, v) in videos.indexed)
        if (has[i]) v,
    ];
    if (episodes.isEmpty) return null;
    episodes.sort((a, b) => a.season != b.season ? a.season!.compareTo(b.season!) : a.episode!.compareTo(b.episode!));
    return ArrivedTitle(group: group, meta: found.meta, episodes: episodes);
  } catch (_) {
    return null;
  }
}

/// The next episode of a requested show that hasn't come out yet.
class UpcomingEpisode {
  const UpcomingEpisode({required this.group, required this.show, required this.video});

  final RequestGroup group;
  final StremioMeta show;
  final StremioVideo video;

  DateTime get airs => video.released!;
}

/// The next episode of each requested show (any show with a request that wasn't declined) that comes out
/// within [horizon] of [now], soonest first. The episode lists come from the catalogs other than the library,
/// which know episodes before they're out. At most [max] shows are looked up.
Future<List<UpcomingEpisode>> findUpcoming(
  TitleSearch search,
  List<RequestGroup> groups, {
  DateTime? now,
  Duration horizon = const Duration(days: 180),
  int max = 24,
}) async {
  final at = now ?? DateTime.now();
  final shows = [
    for (final g in groups)
      if (g.first.kind == 'series' && g.requests.any((r) => r.status != RequestStatus.declined)) g,
  ];
  shows.sort((a, b) {
    if (a.mine != b.mine) return a.mine ? -1 : 1;
    return b.changedAt.compareTo(a.changedAt);
  });
  final found = await Future.wait([
    for (final g in shows.take(max))
      search.details(g.meta).then((full) => _nextEpisode(g, full, at, horizon)).catchError((Object _) => null),
  ]);
  final out = [for (final u in found) ?u];
  out.sort((a, b) => a.airs.compareTo(b.airs));
  return out;
}

UpcomingEpisode? _nextEpisode(RequestGroup group, StremioMeta full, DateTime now, Duration horizon) {
  final until = now.add(horizon);
  StremioVideo? next;
  for (final v in full.videos) {
    final r = v.released;
    if (v.season == null || v.episode == null || v.season! <= 0 || r == null) continue;
    if (!r.isAfter(now) || r.isAfter(until)) continue;
    if (next == null || r.isBefore(next.released!)) next = v;
  }
  if (next == null) return null;
  return UpcomingEpisode(group: group, show: full.id.isEmpty ? group.meta : full, video: next);
}
