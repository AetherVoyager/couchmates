import '../stremio/models.dart';
import '../stremio/stremio_client.dart';

/// One row on the home screen: a catalog and its first page.
class HomeRow {
  const HomeRow({required this.catalog, required this.title, required this.items});

  final StremioCatalog catalog;

  /// The catalog's name with its type, because Telegram-Stremio names both
  /// its movie and series catalogs "Recently Added".
  final String title;
  final List<StremioMeta> items;
}

String typeLabel(String type) => switch (type) {
  'movie' => 'Movies',
  'series' => 'Shows',
  _ => type.isEmpty ? 'Other' : '${type[0].toUpperCase()}${type.substring(1)}',
};

/// The home rows: every catalog that works without input (search-only ones
/// are skipped), in the addon's order, with empty ones left out. A catalog
/// that fails to load is skipped rather than failing the whole screen; if
/// all of them fail, the first error is thrown.
Future<List<HomeRow>> loadHomeRows(StremioClient client) async {
  final manifest = await client.manifest();
  final catalogs = manifest.catalogs.where((c) => !c.needsInput).toList();
  if (catalogs.isEmpty) {
    throw const StremioException(
      'Telegram-Stremio lists no catalogs, so there are no rows to show. Its "Hide Catalog" setting is '
      'probably on: turn it off in the Hub (Settings → Telegram-Stremio) or in Telegram-Stremio\'s own '
      'settings (General → Hide Catalog).',
    );
  }
  Object? firstError;
  final pages = await Future.wait([
    for (final c in catalogs)
      client.catalog(c.type, c.id).catchError((Object e) {
        firstError ??= e;
        return <StremioMeta>[];
      }),
  ]);
  if (firstError != null && pages.every((p) => p.isEmpty)) throw firstError!;
  return [
    for (var i = 0; i < catalogs.length; i++)
      if (pages[i].isNotEmpty)
        HomeRow(catalog: catalogs[i], title: '${typeLabel(catalogs[i].type)} · ${catalogs[i].name}', items: pages[i]),
  ];
}

/// Pages through one catalog for the "see all" grid.
class CatalogPager {
  CatalogPager(this.client, this.catalog, {this.genre});

  final StremioClient client;
  final StremioCatalog catalog;
  final String? genre;

  final List<StremioMeta> items = [];
  final Set<String> _ids = {};
  bool _done = false;
  bool _loading = false;

  bool get done => _done;

  /// Loads the next page. Returns false when there's nothing more.
  Future<bool> loadMore() async {
    if (_done || _loading) return false;
    _loading = true;
    try {
      final page = await client.catalog(catalog.type, catalog.id, skip: items.length, genre: genre);
      final fresh = page.where((m) => _ids.add(m.id)).toList();
      items.addAll(fresh);
      // An empty page, or one of only repeats, means the end.
      if (fresh.isEmpty) _done = true;
      return fresh.isNotEmpty;
    } finally {
      _loading = false;
    }
  }
}
