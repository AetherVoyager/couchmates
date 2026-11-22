/// Stremio addon protocol shapes (manifest, catalogs, metadata, streams), as
/// served by Telegram-Stremio. Parsing is lenient: missing optional fields
/// become null and unknown fields are ignored, because addons vary.
library;

typedef _Json = Map<String, dynamic>;

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) : null));
double? _double(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList() : const [];
List<_Json> _objects(Object? v) => v is List ? v.whereType<_Json>().toList() : const [];

class StremioCatalogExtra {
  const StremioCatalogExtra({required this.name, this.isRequired = false, this.options = const []});

  /// `search`, `genre`, `skip` and so on.
  final String name;
  final bool isRequired;
  final List<String> options;

  factory StremioCatalogExtra.fromJson(_Json j) => StremioCatalogExtra(
    name: j['name'] as String? ?? '',
    isRequired: j['isRequired'] == true,
    options: _strings(j['options']),
  );
}

class StremioCatalog {
  const StremioCatalog({required this.type, required this.id, required this.name, this.extra = const []});

  /// `movie`, `series` and so on.
  final String type;
  final String id;
  final String name;
  final List<StremioCatalogExtra> extra;

  bool supports(String extraName) => extra.any((e) => e.name == extraName);

  /// Needs an extra (such as `search`) on every request, so it can't be
  /// shown as a plain row on the home screen.
  bool get needsInput => extra.any((e) => e.isRequired);

  List<String> get genres => extra.where((e) => e.name == 'genre').expand((e) => e.options).toList();

  factory StremioCatalog.fromJson(_Json j) => StremioCatalog(
    type: j['type'] as String? ?? '',
    id: j['id'] as String? ?? '',
    name: _str(j['name']) ?? _str(j['id']) ?? '',
    // Older manifests list extras as `extraSupported`/`extraRequired` names.
    extra: j['extra'] is List
        ? _objects(j['extra']).map(StremioCatalogExtra.fromJson).toList()
        : [
            for (final n in _strings(j['extraSupported']))
              StremioCatalogExtra(name: n, isRequired: _strings(j['extraRequired']).contains(n)),
          ],
  );
}

class StremioManifest {
  const StremioManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.catalogs,
    required this.resources,
    required this.types,
    this.idPrefixes,
    this.resourceScopes = const {},
  });

  final String id;
  final String name;
  final String version;
  final List<StremioCatalog> catalogs;

  /// `catalog`, `meta`, `stream`…
  final List<String> resources;
  final List<String> types;

  /// The id prefixes it answers for (`tt`, `kitsu:`), or null for any.
  final List<String>? idPrefixes;

  /// Resources given as objects narrow the types and prefixes they answer
  /// for: `{name: (types, idPrefixes)}`, each null when not narrowed.
  final Map<String, ({List<String>? types, List<String>? idPrefixes})> resourceScopes;

  bool hasResource(String name) => resources.contains(name);

  /// Whether it offers [resource] for this [type] and [id], by the rules
  /// Stremio uses to pick which addons to ask.
  bool handles(String resource, String type, String id) {
    if (!hasResource(resource)) return false;
    final scope = resourceScopes[resource];
    final types = scope?.types ?? (this.types.isEmpty ? null : this.types);
    if (types != null && !types.contains(type)) return false;
    final prefixes = scope?.idPrefixes ?? idPrefixes;
    return prefixes == null || prefixes.any(id.startsWith);
  }

  factory StremioManifest.fromJson(_Json j) => StremioManifest(
    id: j['id'] as String? ?? '',
    name: _str(j['name']) ?? 'Catalog',
    version: j['version'] as String? ?? '',
    catalogs: _objects(j['catalogs']).map(StremioCatalog.fromJson).toList(),
    // Resources are either names or `{name, types, idPrefixes}` objects.
    resources: [
      for (final r in (j['resources'] as List? ?? const []))
        if (r is String) r else if (r is _Json && r['name'] is String) r['name'] as String,
    ],
    types: _strings(j['types']),
    idPrefixes: j['idPrefixes'] is List ? _strings(j['idPrefixes']) : null,
    resourceScopes: {
      for (final r in _objects(j['resources']))
        if (r['name'] is String)
          r['name'] as String: (
            types: r['types'] is List ? _strings(r['types']) : null,
            idPrefixes: r['idPrefixes'] is List ? _strings(r['idPrefixes']) : null,
          ),
    },
  );
}

/// A catalog entry (`metas[]`), or the full item when [videos] is filled in
/// from `/meta`.
class StremioMeta {
  const StremioMeta({
    required this.id,
    required this.type,
    required this.name,
    this.poster,
    this.background,
    this.logo,
    this.description,
    this.releaseInfo,
    this.year,
    this.imdbRating,
    this.runtime,
    this.genres = const [],
    this.cast = const [],
    this.directors = const [],
    this.writers = const [],
    this.tmdbId,
    this.trailers = const [],
    this.country,
    this.released,
    this.videos = const [],
  });

  final String id;
  final String type;
  final String name;
  final String? poster;
  final String? background;
  final String? logo;
  final String? description;

  /// Free text such as `2019` or `2019–2022`.
  final String? releaseInfo;
  final int? year;
  final double? imdbRating;

  /// Free text such as `2h 5min` or `45 min`.
  final String? runtime;
  final List<String> genres;
  final List<String> cast;
  final List<String> directors;
  final List<String> writers;

  /// TMDB's id (Telegram-Stremio's `moviedb_id`), for cast photos.
  final int? tmdbId;

  /// YouTube ids of trailers, as Cinemeta lists them.
  final List<String> trailers;
  final String? country;
  final DateTime? released;

  /// Episodes for series (empty for movies and catalog entries).
  final List<StremioVideo> videos;

  bool get isSeries => type == 'series';

  /// Seasons that have episodes, in order. Specials (season 0) come last.
  List<int> get seasons {
    final s = videos.map((v) => v.season).whereType<int>().toSet().toList()..sort();
    if (s.remove(0)) s.add(0);
    return s;
  }

  /// The episode after [videoId] in watching order (specials last), or null.
  StremioVideo? nextAfter(String videoId) {
    final order = [for (final s in seasons) ...episodesOf(s)];
    final i = order.indexWhere((v) => v.id == videoId);
    return i >= 0 && i + 1 < order.length ? order[i + 1] : null;
  }

  List<StremioVideo> episodesOf(int season) =>
      videos.where((v) => v.season == season).toList()..sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));

  factory StremioMeta.fromJson(_Json j) {
    final releaseInfo = _str(j['releaseInfo']) ?? (j['releaseInfo'] is num ? '${j['releaseInfo']}' : null);
    // Telegram-Stremio sends years as text, sometimes a range (`2010-2015`).
    int? firstYear(Object? v) => _int(RegExp(r'\d{4}').firstMatch(v is num ? '$v' : (v as String? ?? ''))?.group(0));
    final year = firstYear(j['year']) ?? firstYear(releaseInfo);
    // `links` carry cast and directors in newer addons.
    final links = _objects(j['links']);
    List<String> linked(String category) => [
      for (final l in links)
        if (l['category'] == category && l['name'] is String) l['name'] as String,
    ];
    final cast = _strings(j['cast']);
    final directors = _strings(j['director']);
    return StremioMeta(
      id: j['id'] as String? ?? '',
      type: j['type'] as String? ?? '',
      name: _str(j['name']) ?? '',
      poster: _str(j['poster']),
      background: _str(j['background']),
      logo: _str(j['logo']),
      description: _str(j['description']),
      releaseInfo: releaseInfo,
      year: year,
      imdbRating: _double(j['imdbRating']),
      runtime: _str(j['runtime']),
      genres: _strings(j['genres']).isNotEmpty ? _strings(j['genres']) : linked('Genres'),
      cast: cast.isNotEmpty ? cast : linked('Cast'),
      directors: directors.isNotEmpty ? directors : linked('Directors'),
      writers: _strings(j['writer']).isNotEmpty ? _strings(j['writer']) : linked('Writers'),
      tmdbId: _int(j['moviedb_id']),
      trailers: [
        for (final t in _objects(j['trailers']))
          if (_str(t['source']) case final id?) id,
        for (final t in _objects(j['trailerStreams']))
          if (_str(t['ytId']) case final id?) id,
      ].toSet().toList(),
      country: _str(j['country']),
      released: DateTime.tryParse(j['released'] as String? ?? ''),
      videos: _objects(j['videos']).map(StremioVideo.fromJson).toList(),
    );
  }
}

/// An episode of a series.
class StremioVideo {
  const StremioVideo({
    required this.id,
    required this.title,
    this.season,
    this.episode,
    this.released,
    this.thumbnail,
    this.overview,
  });

  /// Stream id, usually `<seriesId>:<season>:<episode>`.
  final String id;
  final String title;
  final int? season;
  final int? episode;
  final DateTime? released;
  final String? thumbnail;
  final String? overview;

  factory StremioVideo.fromJson(_Json j) => StremioVideo(
    id: j['id'] as String? ?? '',
    title: _str(j['title']) ?? _str(j['name']) ?? '',
    season: _int(j['season']),
    episode: _int(j['episode']) ?? _int(j['number']),
    released: DateTime.tryParse(j['released'] as String? ?? ''),
    thumbnail: _str(j['thumbnail']),
    overview: _str(j['overview']) ?? _str(j['description']),
  );
}

class StremioStream {
  const StremioStream({
    required this.url,
    this.name,
    this.title,
    this.filename,
    this.sizeBytes,
    this.bingeGroup,
    this.headers = const {},
    this.source,
  });

  final String url;

  /// The add-on it came from, for streams that aren't from the user's own
  /// catalog.
  final String? source;

  /// Short label, often the quality (`1080p`).
  final String? name;

  /// Longer description, often several lines.
  final String? title;
  final String? filename;
  final int? sizeBytes;

  /// Streams sharing this can auto-play into the next episode.
  final String? bingeGroup;

  /// Request headers the player must send (`behaviorHints.proxyHeaders`).
  final Map<String, String> headers;

  String get label => name ?? title?.split('\n').first ?? filename ?? 'Stream';

  /// A playable stream, or null for anything else in the list: torrent
  /// (`infoHash`) and external links, and the notices Telegram-Stremio sends
  /// as streams ("Plan Expired", "Limit Reached", a donation link). Those are
  /// told apart by having no size and no binge group; see [StremioNotice].
  /// Other add-ons send no such notices, so with [strict] off any http(s)
  /// stream counts, and [source] names the add-on.
  static StremioStream? fromJson(_Json j, {bool strict = true, String? source}) {
    final url = _str(j['url']);
    final scheme = url == null ? null : Uri.tryParse(url)?.scheme;
    if (scheme != 'http' && scheme != 'https') return null;
    final hints = j['behaviorHints'] is _Json ? j['behaviorHints'] as _Json : const <String, dynamic>{};
    final size = _int(j['size_bytes']) ?? _int(hints['videoSize']);
    final bingeGroup = _str(hints['bingeGroup']);
    if (strict && size == null && bingeGroup == null) return null;
    final proxy = hints['proxyHeaders'] is _Json ? hints['proxyHeaders'] as _Json : const <String, dynamic>{};
    final request = proxy['request'] is _Json ? proxy['request'] as _Json : const <String, dynamic>{};
    return StremioStream(
      url: url!,
      name: _str(j['name']),
      title: _str(j['title']) ?? _str(j['description']),
      filename: _str(hints['filename']),
      sizeBytes: size,
      bingeGroup: bingeGroup,
      source: source,
      headers: {
        for (final e in request.entries)
          if (e.value is String) e.key: e.value as String,
      },
    );
  }
}

/// Something the catalog server says instead of (or next to) streams, such
/// as "Limit Reached". Shown to the user, never played.
class StremioNotice {
  const StremioNotice({required this.name, this.text});

  final String name;
  final String? text;

  /// Donation and external links aren't notices about this title.
  static StremioNotice? fromJson(_Json j) {
    if (j['externalUrl'] != null || StremioStream.fromJson(j) != null || j['infoHash'] != null) return null;
    final name = _str(j['name']);
    return name == null ? null : StremioNotice(name: name, text: _str(j['title']) ?? _str(j['description']));
  }
}

/// A place to watch a title outside the app, such as a streaming service
/// (a stream's `externalUrl`).
class StremioLink {
  const StremioLink({required this.name, required this.url, this.title, this.source});

  final String name;
  final String? title;
  final Uri url;
  final String? source;

  static StremioLink? fromJson(_Json j, {String? source}) {
    final url = Uri.tryParse(_str(j['externalUrl']) ?? '');
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) return null;
    return StremioLink(
      name: _str(j['name']) ?? url.host,
      title: _str(j['title']) ?? _str(j['description']),
      url: url,
      source: source,
    );
  }
}

class StremioStreams {
  const StremioStreams({required this.streams, required this.notices, this.links = const []});

  final List<StremioStream> streams;
  final List<StremioNotice> notices;

  /// Where else to watch it. Only from add-ons other than the user's own
  /// catalog, whose external links are donation pages.
  final List<StremioLink> links;

  /// [strict] is for the user's own catalog (Telegram-Stremio); see
  /// [StremioStream.fromJson].
  factory StremioStreams.fromJson(_Json j, {bool strict = true, String? source}) {
    final items = (j['streams'] as List? ?? const []).whereType<_Json>().toList();
    return StremioStreams(
      streams: [for (final i in items) ?StremioStream.fromJson(i, strict: strict, source: source)],
      notices: strict ? items.map(StremioNotice.fromJson).whereType<StremioNotice>().toList() : const [],
      links: strict ? const [] : [for (final i in items) ?StremioLink.fromJson(i, source: source)],
    );
  }
}
