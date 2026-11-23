import 'dart:async';

import 'models.dart';
import 'online_subtitles.dart';
import 'stremio_client.dart';

/// A public add-on the admin turned on in the Hub, and its client.
class ExtraSource {
  const ExtraSource({required this.id, required this.name, required this.client});

  /// The Hub's id; catalog ids from this add-on start with `<id>~`.
  final String id;
  final String name;
  final StremioClient client;
}

/// The user's catalog (Telegram-Stremio) and the Hub's public add-ons, used
/// as one addon, the way Stremio combines installed add-ons:
///
/// - the manifest lists the catalog's catalogs first, then each add-on's, so
///   home rows keep that order. An add-on's catalog ids are prefixed with
///   `<add-on id>~` so they reach the right add-on again.
/// - details come from the first that has them, the catalog first.
/// - streams and subtitles are merged from all that offer them for the id.
///
/// Add-ons that fail are skipped; the catalog's errors are kept, so its
/// explanations (such as "Hide Catalog" being on) still reach the user.
class AddonSet extends StremioClient {
  AddonSet({this.primary, this.extras = const [], this.fallbackSubtitles}) : super(baseUrl: primary?.baseUrl ?? '');

  /// The user's catalog, or null when the admin hasn't connected one.
  final StremioClient? primary;
  final List<ExtraSource> extras;

  /// Asked for subtitles when no add-on in [extras] offers them (Stremio's
  /// OpenSubtitles add-on).
  final StremioClient? fallbackSubtitles;

  static const separator = '~';

  final Map<StremioClient, Future<StremioManifest?>> _manifests = {};
  StremioManifest? _merged;

  /// An extra add-on's manifest, or null when it can't be read now (tried
  /// again on the next call).
  Future<StremioManifest?> _manifestOf(StremioClient c) {
    return _manifests[c] ??= c.manifest().then<StremioManifest?>((m) => m).catchError((Object _) {
      unawaited(Future(() => _manifests.remove(c)));
      return null;
    });
  }

  @override
  Future<StremioManifest> manifest({bool refresh = false}) async {
    if (!refresh && _merged != null) return _merged!;
    if (refresh) _manifests.clear();
    final extraManifests = await Future.wait([for (final e in extras) _manifestOf(e.client)]);
    StremioManifest? own;
    Object? ownError;
    if (primary != null) {
      try {
        own = await primary!.manifest(refresh: refresh);
      } catch (e) {
        ownError = e;
      }
    }
    final catalogs = <StremioCatalog>[...?own?.catalogs];
    final names = {for (final c in catalogs) '${c.type}/${c.name}'};
    for (var i = 0; i < extras.length; i++) {
      final m = extraManifests[i];
      if (m == null) continue;
      for (final c in m.catalogs) {
        // Two "Popular" rows of the same type get the add-on's name.
        final name = names.add('${c.type}/${c.name}') ? c.name : '${c.name} (${extras[i].name})';
        catalogs.add(StremioCatalog(type: c.type, id: '${extras[i].id}$separator${c.id}', name: name, extra: c.extra));
      }
    }
    // Without the catalog, the add-ons alone are enough to browse.
    if (ownError != null && catalogs.isEmpty) throw ownError;
    final all = [?own, ...extraManifests.nonNulls];
    final merged = StremioManifest(
      id: own?.id ?? 'couchmates.addons',
      name: own?.name ?? 'Add-ons',
      version: own?.version ?? '',
      catalogs: catalogs,
      resources: {for (final m in all) ...m.resources}.toList(),
      types: {for (final m in all) ...m.types}.toList(),
    );
    // A missing catalog is worth asking again; a full set is kept.
    if (ownError == null && !extraManifests.contains(null)) _merged = merged;
    return merged;
  }

  /// The client and real id for a catalog id from [manifest].
  (StremioClient, String)? _route(String catalogId) {
    final i = catalogId.indexOf(separator);
    if (i > 0) {
      final key = catalogId.substring(0, i);
      for (final e in extras) {
        if (e.id == key) return (e.client, catalogId.substring(i + 1));
      }
    }
    final own = primary;
    return own == null ? null : (own, catalogId);
  }

  @override
  Future<List<StremioMeta>> catalog(String type, String id, {int skip = 0, String? genre, String? search}) async {
    final route = _route(id);
    if (route == null) return const [];
    return route.$1.catalog(type, route.$2, skip: skip, genre: genre, search: search);
  }

  /// The extra add-ons that offer [resource] for this title, in order.
  Future<List<ExtraSource>> _offering(String resource, String type, String id) async {
    final manifests = await Future.wait([for (final e in extras) _manifestOf(e.client)]);
    return [
      for (var i = 0; i < extras.length; i++)
        if (manifests[i]?.handles(resource, type, id) ?? false) extras[i],
    ];
  }

  /// Whether one of the public add-ons can play this title, so it's watchable without being in the catalog.
  Future<bool> streamsElsewhere(String type, String id) async => (await _offering('stream', type, id)).isNotEmpty;

  @override
  Future<StremioMeta?> meta(String type, String id) async {
    Object? ownError;
    if (primary != null) {
      try {
        final m = await primary!.meta(type, id);
        if (m != null) return m;
      } catch (e) {
        ownError = e;
      }
    }
    for (final e in await _offering('meta', type, id)) {
      try {
        final m = await e.client.meta(type, id);
        if (m != null) return m;
      } catch (_) {}
    }
    if (ownError != null) throw ownError;
    return null;
  }

  @override
  Future<StremioStreams> streams(String type, String id) async {
    final others = await _offering('stream', type, id);
    Object? ownError;
    final own = primary == null
        ? Future<StremioStreams?>.value(null)
        : primary!.streams(type, id).then<StremioStreams?>((s) => s).catchError((Object e) {
            ownError = e;
            return null;
          });
    final results = await Future.wait([
      own,
      for (final e in others) e.client.streams(type, id).then<StremioStreams?>((s) => s).catchError((Object _) => null),
    ]);
    final found = results.nonNulls.toList();
    final merged = StremioStreams(
      streams: [for (final r in found) ...r.streams],
      notices: [for (final r in found) ...r.notices],
      links: [for (final r in found) ...r.links],
    );
    if (ownError != null && merged.streams.isEmpty && merged.links.isEmpty) throw ownError!;
    return merged;
  }

  @override
  Future<List<OnlineSubtitle>> subtitles(String type, String id, {String? filename, int? videoSize}) async {
    final others = await _offering('subtitles', type, id);
    final ownManifest = primary == null ? null : await _manifestOf(primary!);
    final clients = [
      if (ownManifest?.handles('subtitles', type, id) ?? false) primary!,
      for (final e in others) e.client,
      if (others.isEmpty) ?fallbackSubtitles,
    ];
    final results = await Future.wait([
      for (final c in clients)
        c
            .subtitles(type, id, filename: filename, videoSize: videoSize)
            .catchError((Object _) => const <OnlineSubtitle>[]),
    ]);
    final seen = <String>{};
    return [
      for (final list in results)
        for (final s in list)
          if (seen.add(s.url)) s,
    ];
  }

  @override
  void close() {
    primary?.close();
    for (final e in extras) {
      e.client.close();
    }
    fallbackSubtitles?.close();
    super.close();
  }
}
