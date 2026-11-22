import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'online_subtitles.dart';

class StremioException implements Exception {
  const StremioException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'StremioException($status): $message';
}

/// A client for one Stremio addon: the user's catalog, at the base URL the
/// Hub hands out in `AppConfig.addon`.
class StremioClient {
  StremioClient({
    required String baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.name,
    this.strictStreams = true,
  }) : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
       _http = httpClient ?? http.Client();

  final String baseUrl;
  final Duration timeout;

  /// The add-on's name, put on its streams. Null for the user's own catalog.
  final String? name;

  /// Telegram-Stremio's stream rules (see [StremioStreams.fromJson]); off
  /// for other add-ons.
  final bool strictStreams;
  final http.Client _http;
  StremioManifest? _manifest;

  /// One path segment, percent-encoded the way addons expect (ids such as
  /// `tt123:1:2` keep their colons).
  static String _segment(String s) => Uri.encodeComponent(s).replaceAll('%3A', ':');

  /// `/catalog/movie/top/skip=20&genre=Drama.json`.
  static String catalogPath(String type, String id, {Map<String, String> extra = const {}}) {
    final extras = extra.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '/catalog/${_segment(type)}/${_segment(id)}${extras.isEmpty ? '' : '/$extras'}.json';
  }

  /// [missingOk]: a 404 means "nothing here" (unknown title) rather than a
  /// broken setup, so it reads as an empty answer.
  Future<Map<String, dynamic>> _get(String path, {bool missingOk = false}) async {
    final http.Response response;
    try {
      response = await _http.get(Uri.parse('$baseUrl$path'), headers: {'accept': 'application/json'}).timeout(timeout);
    } catch (_) {
      throw const StremioException("Couldn't reach the catalog server.");
    }
    final status = response.statusCode;
    if (status == 404 && missingOk) return const {};
    if (status < 200 || status >= 300) throw StremioException(_problem(status, _detail(response)), status: status);
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    throw const StremioException('The catalog server sent something unreadable.');
  }

  /// FastAPI's `{"detail": ...}`, if any.
  static String _detail(http.Response r) {
    try {
      final decoded = jsonDecode(utf8.decode(r.bodyBytes));
      if (decoded is Map && decoded['detail'] is String) return decoded['detail'] as String;
    } catch (_) {}
    return '';
  }

  static String _problem(int status, String detail) {
    if (status == 401 || status == 403) {
      return "The catalog server didn't accept your access. Ask your admin to check your account in the Hub.";
    }
    if (status == 404 && detail.toLowerCase().contains('disabled')) {
      return 'Catalogs are turned off in Telegram-Stremio ("Hide Catalog"). Turn it off in the Hub: Settings → Telegram-Stremio.';
    }
    if (status == 404) {
      return "The catalog server has nothing at this address. Ask your admin to check the Hub's Telegram-Stremio address.";
    }
    return 'The catalog server answered with an error ($status${detail.isEmpty ? '' : ': $detail'}).';
  }

  /// The addon's manifest, fetched once.
  Future<StremioManifest> manifest({bool refresh = false}) async {
    if (!refresh && _manifest != null) return _manifest!;
    return _manifest = StremioManifest.fromJson(await _get('/manifest.json'));
  }

  /// A page of a catalog. Pass [skip] (items already loaded) for later
  /// pages; Telegram-Stremio pages in 15s. [genre] and [search] only work on
  /// catalogs that list them. Items without an id are dropped.
  Future<List<StremioMeta>> catalog(String type, String id, {int skip = 0, String? genre, String? search}) async {
    final json = await _get(
      catalogPath(
        type,
        id,
        extra: {if (search != null) 'search': search, if (genre != null) 'genre': genre, if (skip > 0) 'skip': '$skip'},
      ),
    );
    return (json['metas'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(StremioMeta.fromJson)
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  /// Full details, with episodes for series. Null if the addon doesn't know
  /// the item.
  Future<StremioMeta?> meta(String type, String id) async {
    final json = await _get('/meta/${_segment(type)}/${_segment(id)}.json', missingOk: true);
    final meta = json['meta'];
    return meta is Map<String, dynamic> ? StremioMeta.fromJson(meta) : null;
  }

  /// Streams for a movie id, or an episode's video id, plus any notices
  /// (such as "Limit Reached") the server sent instead.
  Future<StremioStreams> streams(String type, String id) async => StremioStreams.fromJson(
    await _get('/stream/${_segment(type)}/${_segment(id)}.json', missingOk: true),
    strict: strictStreams,
    source: name,
  );

  /// Subtitles for a movie id or an episode's `tt…:season:episode` id, from
  /// a subtitles addon. [filename] and [videoSize] (bytes) help it rank the
  /// files that fit this release first.
  Future<List<OnlineSubtitle>> subtitles(String type, String id, {String? filename, int? videoSize}) async {
    final extras = {'filename': ?filename, if (videoSize != null) 'videoSize': '$videoSize'}.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final json = await _get(
      '/subtitles/${_segment(type)}/${_segment(id)}${extras.isEmpty ? '' : '/$extras'}.json',
      missingOk: true,
    );
    return [
      for (final s in (json['subtitles'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ?OnlineSubtitle.fromJson(s),
    ];
  }

  /// Searches every catalog that supports it, merged in catalog order
  /// without duplicates.
  Future<List<StremioMeta>> search(String query) async {
    final m = await manifest();
    final results = await Future.wait([
      for (final c in m.catalogs)
        if (c.supports('search')) catalog(c.type, c.id, search: query).catchError((_) => <StremioMeta>[]),
    ]);
    final seen = <String>{};
    return [
      for (final list in results)
        for (final item in list)
          if (seen.add('${item.type}/${item.id}')) item,
    ];
  }

  void close() => _http.close();
}
