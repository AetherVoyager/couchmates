import '../settings/app_settings.dart';
import '../settings/track_choice.dart';
import '../watch/watch_room.dart';
import 'stremio_client.dart';

/// Stremio's official OpenSubtitles addon: subtitles only, looked up by IMDb
/// id (`tt0133093`, or `tt0903747:1:2` for an episode).
const openSubtitlesAddon = 'https://opensubtitles-v3.strem.io';

/// One subtitle file a subtitles addon offers. [url] serves it as UTF-8 text
/// (SRT, usually) that mpv loads as an external track.
class OnlineSubtitle {
  const OnlineSubtitle({required this.id, required this.url, required this.language, this.fileName});

  final String id;
  final String url;

  /// As the addon sends it: ISO 639-2 (`eng`, `ger`) or OpenSubtitles' own
  /// (`pob` for Brazilian Portuguese).
  final String language;
  final String? fileName;

  static OnlineSubtitle? fromJson(Map<String, dynamic> j) {
    final url = j['url'];
    final scheme = url is String ? Uri.tryParse(url)?.scheme : null;
    if (scheme != 'http' && scheme != 'https') return null;
    final id = j['id'];
    final lang = j['lang'];
    final name = j['subtitleFileName'];
    return OnlineSubtitle(
      id: id is String ? id : '${id ?? url}',
      url: url as String,
      language: lang is String && lang.isNotEmpty ? lang : 'und',
      fileName: name is String && name.isNotEmpty ? name : null,
    );
  }
}

/// The `type` and `id` a subtitles addon knows [p] by, or null when the title
/// has no IMDb id (subtitle addons don't search by name).
({String type, String id})? subtitleLookup(Playable p) {
  final imdb = p.meta.id;
  if (!RegExp(r'^tt\d+$').hasMatch(imdb)) return null;
  final v = p.video;
  if (v == null) return (type: 'movie', id: imdb);
  if (v.season == null || v.episode == null) return null;
  return (type: 'series', id: '$imdb:${v.season}:${v.episode}');
}

/// Fetches OpenSubtitles' list for [p]. The file's name and size, when known,
/// help the addon rank the subtitles that fit this release first. Empty when
/// the title can't be looked up or the addon can't be reached.
Future<List<OnlineSubtitle>> fetchOnlineSubtitles(StremioClient addon, Playable p) async {
  final key = subtitleLookup(p);
  if (key == null) return const [];
  try {
    return await addon.subtitles(key.type, key.id, filename: p.stream.filename, videoSize: p.stream.sizeBytes);
  } on StremioException {
    return const [];
  }
}

/// The languages to offer online subtitles in, as two-letter codes: the
/// subtitle languages in Settings, else the audio ones, else English.
List<String> onlineSubtitleLanguages(AppSettings s) {
  final wanted = s.subtitleLanguages.isNotEmpty ? s.subtitleLanguages : s.audioLanguages;
  return wanted.isEmpty ? const ['en'] : [for (final l in wanted) normalizeLanguage(l)];
}

/// What the subtitle menu offers from [all]: up to [perLanguage] in each of
/// [languages], in that order and in the addon's order within a language.
/// When none of them has any, up to [fallback] in any language instead, so
/// the menu still shows something for a title nobody subtitled in yours.
List<OnlineSubtitle> pickOnlineSubtitles(
  List<OnlineSubtitle> all,
  List<String> languages, {
  int perLanguage = 3,
  int fallback = 8,
}) {
  final picked = <OnlineSubtitle>[];
  for (final lang in languages) {
    picked.addAll(all.where((s) => normalizeLanguage(s.language) == lang).take(perLanguage));
  }
  if (picked.isNotEmpty) return picked;
  return all.take(fallback).toList();
}

/// The language to load an online subtitle in when the player starts, or
/// null. It's the choice [chooseSubtitle] would make with one online track
/// added for each wanted language the file has no full subtitles in, so the
/// file's own tracks still win, and "Never" or understood audio still mean
/// none.
String? autoOnlineLanguage(List<TrackInfo> fileSubtitles, AppSettings s, {required String? audioLanguage}) {
  final wanted = s.subtitleLanguages.isNotEmpty ? s.subtitleLanguages : s.audioLanguages;
  final inFile = {
    for (final t in fileSubtitles)
      if (!t.forced) normalizeLanguage(t.language),
  };
  final online = [
    for (final l in wanted)
      if (!inFile.contains(normalizeLanguage(l)))
        TrackInfo(id: 'online:${normalizeLanguage(l)}', language: normalizeLanguage(l)),
  ];
  if (online.isEmpty) return null;
  final id = chooseSubtitle(
    [...fileSubtitles, ...online],
    mode: s.subtitleMode,
    preferredSubtitles: s.subtitleLanguages,
    preferredAudio: s.audioLanguages,
    audioLanguage: audioLanguage,
  );
  return id != null && id.startsWith('online:') ? id.substring('online:'.length) : null;
}
