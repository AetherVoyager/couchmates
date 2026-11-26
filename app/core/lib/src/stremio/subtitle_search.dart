import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../hub/api.dart';
import '../settings/track_choice.dart';
import '../watch/watch_room.dart';
import 'online_subtitles.dart';

/// One subtitle the player's search offers: from OpenSubtitles through the
/// Hub (downloaded by [fileId] first), or from the free add-on (loaded from
/// [url] as it is).
class SubtitleChoice {
  const SubtitleChoice({
    required this.language,
    required this.label,
    this.downloads,
    this.hearingImpaired = false,
    this.machineTranslated = false,
    this.hashMatch = false,
    this.fileId,
    this.url,
  }) : assert((fileId == null) != (url == null));

  factory SubtitleChoice.fromHub(SubtitleResult r) => SubtitleChoice(
    language: normalizeLanguage(r.language),
    label: r.release.isNotEmpty ? r.release : (r.fileName ?? 'Subtitle ${r.fileId}'),
    downloads: r.downloads,
    hearingImpaired: r.hearingImpaired,
    machineTranslated: r.machineTranslated,
    hashMatch: r.hashMatch,
    fileId: r.fileId,
  );

  factory SubtitleChoice.fromAddon(OnlineSubtitle s, int number) =>
      SubtitleChoice(language: normalizeLanguage(s.language), label: s.fileName ?? 'Subtitle $number', url: s.url);

  /// Two letters (`en`), or what the source sent when it has no such code.
  final String language;

  /// The release it was made for, or the file's name.
  final String label;
  final int? downloads;
  final bool hearingImpaired;
  final bool machineTranslated;

  /// Made for this very file, so it's in sync.
  final bool hashMatch;
  final int? fileId;
  final String? url;

  bool get fromHub => fileId != null;

  /// Tells choices apart, and remembers which are loaded.
  String get key => fileId != null ? 'os:$fileId' : 'url:$url';
}

/// What to ask the Hub for [p]: by IMDb id (and season and episode) when the
/// title has one, else by [query] or the title's name. A [query] typed by the
/// user replaces the id, so a wrong id can be searched around.
SubtitleSearchRequest subtitleRequestFor(Playable p, {required List<String> languages, String? query, String? hash}) {
  final typed = query?.trim();
  final imdb = RegExp(r'^tt\d+$').hasMatch(p.meta.id) ? p.meta.id : null;
  final useId = imdb != null && (typed == null || typed.isEmpty);
  return SubtitleSearchRequest(
    imdb: useId ? imdb : null,
    season: p.video?.season,
    episode: p.video?.episode,
    query: useId ? null : (typed == null || typed.isEmpty ? p.meta.name : typed),
    languages: languages,
    hash: hash,
  );
}

/// The search's list in [language] (every language when null): subtitles
/// made for this file first, then the Hub's by popularity, then the add-on's.
List<SubtitleChoice> subtitleChoices({
  SubtitleSearch hub = SubtitleSearch.none,
  List<OnlineSubtitle> addon = const [],
  String? language,
}) {
  bool wanted(SubtitleChoice c) => language == null || c.language == language;
  final fromHub = [for (final r in hub.results) SubtitleChoice.fromHub(r)].where(wanted).toList();
  final fromAddon = [for (final (i, s) in addon.indexed) SubtitleChoice.fromAddon(s, i + 1)].where(wanted).toList();
  return [...fromHub.where((c) => c.hashMatch), ...fromHub.where((c) => !c.hashMatch), ...fromAddon];
}

const _chunk = 65536;

/// OpenSubtitles' hash of a file: its size plus the 64-bit little-endian
/// words of its first and last 64 KiB, wrapping, as 16 hex digits.
String openSubtitlesHash(Uint8List head, Uint8List tail, int size) {
  // Two 32-bit halves with carries, so it's the same on every platform.
  var lo = size & 0xFFFFFFFF, hi = (size ~/ 0x100000000) & 0xFFFFFFFF;
  for (final bytes in [head, tail]) {
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 8 <= bytes.length; i += 8) {
      lo += data.getUint32(i, Endian.little);
      hi += data.getUint32(i + 4, Endian.little) + (lo >> 32);
      lo &= 0xFFFFFFFF;
      hi &= 0xFFFFFFFF;
    }
  }
  return hi.toRadixString(16).padLeft(8, '0') + lo.toRadixString(16).padLeft(8, '0');
}

/// The hash of what [p] streams, from two range requests (the first and last
/// 64 KiB), or null when the server can't serve ranges, the size is unknown
/// or it takes too long.
Future<String?> fetchOpenSubtitlesHash(
  Playable p, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final own = client == null;
  final http_ = client ?? http.Client();
  try {
    final first = await _range(http_, p, 0, _chunk - 1).timeout(timeout);
    final size = p.stream.sizeBytes ?? first?.total;
    if (first == null || size == null || size < _chunk * 2) return null;
    final last = await _range(http_, p, size - _chunk, size - 1).timeout(timeout);
    if (last == null) return null;
    return openSubtitlesHash(first.bytes, last.bytes, size);
  } catch (_) {
    return null;
  } finally {
    if (own) http_.close();
  }
}

/// Bytes [from] to [to] of the stream, and the file's size if the server
/// says. Null unless the server answers with exactly that range.
Future<({Uint8List bytes, int? total})?> _range(http.Client client, Playable p, int from, int to) async {
  final uri = Uri.tryParse(p.url);
  if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) return null;
  final req = http.Request('GET', uri)
    ..headers.addAll(p.headers)
    ..headers['range'] = 'bytes=$from-$to';
  final resp = await client.send(req);
  if (resp.statusCode != 206) {
    // A server that ignores ranges would send the whole file: stop reading.
    unawaited(resp.stream.listen(null).cancel());
    return null;
  }
  final want = to - from + 1;
  final out = BytesBuilder(copy: false);
  await for (final chunk in resp.stream) {
    out.add(chunk);
    if (out.length >= want) break;
  }
  final bytes = out.takeBytes();
  if (bytes.length < want) return null;
  final total = int.tryParse(resp.headers['content-range']?.split('/').last ?? '');
  return (bytes: Uint8List.sublistView(bytes, 0, want), total: total);
}
