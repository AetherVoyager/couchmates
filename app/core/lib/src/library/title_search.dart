import 'dart:async';

import '../hub/api.dart';
import '../stremio/models.dart';
import '../stremio/stremio_client.dart';

/// Stremio's own catalog add-on. Search asks it too, so any movie or show can be found and requested, even when
/// nothing the admin set up has it.
const cinemetaAddon = 'https://v3-cinemeta.strem.io';

/// A search result, and whether it's in the user's library (their Telegram-Stremio catalog).
class SearchHit {
  const SearchHit(this.meta, {required this.inLibrary});

  final StremioMeta meta;
  final bool inLibrary;
}

/// Searches the library and everything else that can find titles (the Hub's add-ons and [cinemetaAddon]), so a
/// title that isn't in the library can still be found and asked for.
///
/// Library hits come first. A title from elsewhere that the library also has is left out, matched by id or,
/// for libraries without IMDb ids, by type, name and year.
class TitleSearch {
  TitleSearch({this.library, this.sources = const []});

  /// The user's catalog, or null when the admin hasn't connected one.
  final StremioClient? library;

  /// Searched after the library, in order.
  final List<StremioClient> sources;

  Future<List<SearchHit>> search(String query) async {
    Object? libraryError;
    final own = library == null
        ? Future.value(const <StremioMeta>[])
        : library!.search(query).catchError((Object e) {
            libraryError = e;
            return const <StremioMeta>[];
          });
    var failed = 0;
    final others = [
      for (final s in sources)
        s.search(query).catchError((Object _) {
          failed++;
          return const <StremioMeta>[];
        }),
    ];
    final results = await Future.wait([own, ...others]);
    final mine = results.first;
    if (libraryError != null && failed == sources.length) throw libraryError!;

    final ids = <String>{};
    final names = <String>{};
    final hits = <SearchHit>[];
    for (final m in mine) {
      if (ids.add(_idKey(m))) hits.add(SearchHit(m, inLibrary: true));
      names.add(_nameKey(m));
    }
    for (final list in results.skip(1)) {
      for (final m in list) {
        if (!ids.add(_idKey(m)) || names.contains(_nameKey(m))) continue;
        hits.add(SearchHit(m, inLibrary: false));
      }
    }
    return hits;
  }

  /// Fuller details for a title that isn't in the library, from the first source that has them; [meta] itself
  /// when none does.
  Future<StremioMeta> details(StremioMeta meta) async {
    for (final s in sources) {
      try {
        final full = await s.meta(meta.type, meta.id);
        if (full != null) return full;
      } catch (_) {}
    }
    return meta;
  }

  /// What the app knows about [item] when it's opened: the library's details when the library has it (by id, or
  /// by name and year for libraries without IMDb ids), otherwise the other catalogs'. For a show, [TitleLookup.
  /// full] is every episode it has, from the other catalogs, so the ones the library lacks can be asked for.
  /// Throws what the library throws, so a library that can't be reached isn't taken for one without the title.
  Future<TitleLookup> lookUp(StremioMeta item) async {
    final own = library == null ? null : await _inLibrary(item);
    if (own != null) {
      final full = own.isSeries ? await _fullListing(own) : null;
      return TitleLookup(meta: own, inLibrary: true, full: full);
    }
    final found = await details(item);
    return TitleLookup(meta: found, inLibrary: false, full: found.isSeries ? found : null);
  }

  Future<StremioMeta?> _inLibrary(StremioMeta item) async {
    final byId = await library!.meta(item.type, item.id);
    if (byId != null) return byId;
    // A library without IMDb ids: the same title by name and year.
    if (item.name.trim().isEmpty) return null;
    final List<StremioMeta> hits;
    try {
      hits = await library!.search(item.name);
    } catch (_) {
      return null;
    }
    final key = _nameKey(item);
    final match = hits.where((m) => _nameKey(m) == key).firstOrNull;
    if (match == null) return null;
    return await library!.meta(match.type, match.id) ?? match;
  }

  /// [own]'s full episode list from the other catalogs, or null when none knows it.
  Future<StremioMeta?> _fullListing(StremioMeta own) async {
    for (final s in sources) {
      try {
        final m = await s.meta(own.type, own.id);
        if (m != null && m.videos.isNotEmpty) return m;
      } catch (_) {}
    }
    // Not by id (a library without IMDb ids): by name and year.
    final key = _nameKey(own);
    for (final s in sources) {
      try {
        final match = (await s.search(own.name)).where((m) => _nameKey(m) == key).firstOrNull;
        if (match == null) continue;
        final m = await s.meta(match.type, match.id);
        if (m != null && m.videos.isNotEmpty) return m;
      } catch (_) {}
    }
    return null;
  }

  void close() {
    for (final s in sources) {
      s.close();
    }
  }

  static String _idKey(StremioMeta m) => '${m.type}/${m.id}';

  static String _nameKey(StremioMeta m) =>
      '${m.type}/${m.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '')}/${yearOf(m) ?? ''}';

  /// The first year in [m]'s release info, as text.
  static String? yearOf(StremioMeta m) => m.year?.toString() ?? RegExp(r'\d{4}').firstMatch(m.releaseInfo ?? '')?[0];
}

/// An opened title: what to show, whether the library has it, and for a show, every episode it has.
class TitleLookup {
  const TitleLookup({required this.meta, required this.inLibrary, this.full, bool? playable})
    : playable = playable ?? inLibrary;

  /// The library's details when [inLibrary], otherwise another catalog's.
  final StremioMeta meta;
  final bool inLibrary;

  /// Whether it can be played: it's in the library, or a public add-on streams it.
  final bool playable;

  /// For a show: its full episode list from a catalog other than the library (or [meta] itself when it isn't in
  /// the library). Null for movies, or when no catalog knows the show's episodes.
  final StremioMeta? full;

  /// Episodes of a show in the library that the library doesn't have yet, from [full].
  List<StremioVideo> missing({DateTime? now}) =>
      inLibrary && full != null ? missingEpisodes(meta, full!, now: now) : const [];
}

/// Whether [v] is an episode that has come out, so it can be asked for: numbered, not a special (season 0), and
/// released before [now]. One without a date counts as out.
bool isRequestableEpisode(StremioVideo v, {DateTime? now}) {
  final s = v.season, e = v.episode;
  if (s == null || e == null || s <= 0) return false;
  final released = v.released;
  return released == null || released.isBefore(now ?? DateTime.now());
}

/// The episodes in [full] that have come out and aren't in [library], by season and episode number, in order.
List<StremioVideo> missingEpisodes(StremioMeta library, StremioMeta full, {DateTime? now}) {
  final have = {for (final v in library.videos) '${v.season}:${v.episode}'};
  final seen = <String>{};
  final out = [
    for (final v in full.videos)
      if (isRequestableEpisode(v, now: now) &&
          !have.contains('${v.season}:${v.episode}') &&
          seen.add('${v.season}:${v.episode}'))
        v,
  ];
  out.sort((a, b) => a.season != b.season ? a.season!.compareTo(b.season!) : a.episode!.compareTo(b.episode!));
  return out;
}

/// What to send the Hub to ask for [meta].
/// [video] asks for that one episode of the show.
MediaRequestCreate requestFor(StremioMeta meta, {StremioVideo? video}) => MediaRequestCreate(
  kind: meta.isSeries ? 'series' : 'movie',
  titleId: meta.id,
  name: meta.name,
  year: _yearText(meta),
  poster: _posterOf(meta),
  season: video?.season,
  episode: video?.season == null ? null : video?.episode,
  episodeTitle: video == null || video.title.trim().isEmpty ? null : video.title.trim(),
);

/// What to send the Hub to ask for [episodes] of the show [meta] (at most [MediaRequestEpisodes.maxEpisodes]).
MediaRequestEpisodes episodesRequestFor(StremioMeta meta, List<StremioVideo> episodes) => MediaRequestEpisodes(
  titleId: meta.id,
  name: meta.name,
  year: _yearText(meta),
  poster: _posterOf(meta),
  episodes: [
    for (final v in episodes)
      if (v.season != null && v.episode != null)
        EpisodeAsk(season: v.season!, episode: v.episode!, title: v.title.trim().isEmpty ? null : v.title.trim()),
  ],
);

String? _yearText(StremioMeta meta) =>
    (meta.releaseInfo?.trim().isNotEmpty ?? false) ? meta.releaseInfo!.trim() : meta.year?.toString();

String? _posterOf(StremioMeta meta) => (meta.poster?.startsWith('https://') ?? false) ? meta.poster : null;

/// A movie or show and the requests for it: the request itself, or one per episode.
class RequestGroup {
  const RequestGroup(this.requests);

  /// Episodes in order; never empty.
  final List<MediaRequest> requests;

  MediaRequest get first => requests.first;
  bool get mine => requests.any((r) => r.mine);
  bool get isEpisodes => requests.any((r) => r.isEpisode);

  /// The status that matters most: waiting ones first, then approved, added, declined.
  String get status {
    for (final s in const [RequestStatus.pending, RequestStatus.approved, RequestStatus.added]) {
      if (requests.any((r) => r.status == s)) return s;
    }
    return RequestStatus.declined;
  }

  /// Every request answered for good (Added or Declined).
  bool get finished => requests.every((r) => !r.open);

  /// When any of its requests last changed.
  int get changedAt => requests.map((r) => r.updatedAt).reduce((a, b) => a > b ? a : b);

  /// "S1 E2, E3 · S2 E1" for episodes; null otherwise.
  String? get episodesText {
    if (!isEpisodes) return null;
    final bySeason = <int, List<int>>{};
    for (final r in requests.where((r) => r.isEpisode)) {
      bySeason.putIfAbsent(r.season!, () => []).add(r.episode!);
    }
    final seasons = bySeason.keys.toList()..sort();
    return [for (final s in seasons) 'S$s ${(bySeason[s]!..sort()).map((e) => 'E$e').join(', ')}'].join(' · ');
  }

  /// The movie or show as a catalog entry, to open it.
  StremioMeta get meta =>
      StremioMeta(id: first.titleId, type: first.kind, name: first.name, poster: first.poster, releaseInfo: first.year);
}

/// [requests] by title, in the order their newest request comes; each title's episodes in order.
List<RequestGroup> groupRequests(List<MediaRequest> requests) {
  final groups = <String, List<MediaRequest>>{};
  for (final r in requests) {
    groups.putIfAbsent('${r.kind}/${r.titleId}', () => []).add(r);
  }
  return [
    for (final list in groups.values)
      RequestGroup(
        list..sort((a, b) {
          final s = (a.season ?? -1).compareTo(b.season ?? -1);
          return s != 0 ? s : (a.episode ?? -1).compareTo(b.episode ?? -1);
        }),
      ),
  ];
}

/// [groups] without the finished ones that last changed at or before [clearedAt] (seconds), which the user
/// cleared from their list. Waiting ones always stay.
List<RequestGroup> withoutCleared(List<RequestGroup> groups, int clearedAt) => [
  for (final g in groups)
    if (!g.finished || g.changedAt > clearedAt) g,
];
