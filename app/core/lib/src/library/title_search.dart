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

/// What to send the Hub to ask for [meta].
MediaRequestCreate requestFor(StremioMeta meta) => MediaRequestCreate(
  kind: meta.isSeries ? 'series' : 'movie',
  titleId: meta.id,
  name: meta.name,
  year: (meta.releaseInfo?.trim().isNotEmpty ?? false) ? meta.releaseInfo!.trim() : meta.year?.toString(),
  poster: (meta.poster?.startsWith('https://') ?? false) ? meta.poster : null,
);
