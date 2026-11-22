import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../hub/api.dart';
import 'models.dart';
import 'stream_details.dart';

enum MediaTrackKind { video, audio, subtitle }

/// One track of a file, read from its container before playing.
class MediaTrack {
  const MediaTrack({
    required this.kind,
    required this.index,
    this.codec,
    this.language,
    this.name,
    this.channels,
    this.width,
    this.height,
    this.isDefault = false,
    this.isForced = false,
  });

  final MediaTrackKind kind;

  /// 1-based position among the tracks of its kind, in file order. mpv numbers
  /// a file's tracks the same way, so this is the player's track id.
  final int index;

  /// A readable codec name (`HEVC`, `E-AC3`, `SRT`), or the raw id when unknown.
  final String? codec;

  /// The container's language code (`eng`, `mal`, `en-US`), null when unset.
  final String? language;
  final String? name;
  final int? channels;
  final int? width;
  final int? height;
  final bool isDefault;
  final bool isForced;

  Map<String, Object?> toJson() => {
    'k': kind.name,
    'i': index,
    'c': ?codec,
    'l': ?language,
    'n': ?name,
    'ch': ?channels,
    'w': ?width,
    'h': ?height,
    if (isDefault) 'd': true,
    if (isForced) 'f': true,
  };

  static MediaTrack? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = MediaTrackKind.values.where((k) => k.name == j['k']).firstOrNull;
    final index = j['i'];
    if (kind == null || index is! int) return null;
    T? as<T>(Object? v) => v is T ? v : null;
    return MediaTrack(
      kind: kind,
      index: index,
      codec: as<String>(j['c']),
      language: as<String>(j['l']),
      name: as<String>(j['n']),
      channels: as<int>(j['ch']),
      width: as<int>(j['w']),
      height: as<int>(j['h']),
      isDefault: j['d'] == true,
      isForced: j['f'] == true,
    );
  }

  @override
  String toString() => 'MediaTrack(${kind.name} #$index $language $codec ${name ?? ''})';
}

/// The tracks of a file, by kind.
class MediaTracks {
  const MediaTracks({this.video = const [], this.audio = const [], this.subtitles = const []});

  final List<MediaTrack> video;
  final List<MediaTrack> audio;
  final List<MediaTrack> subtitles;

  bool get isEmpty => video.isEmpty && audio.isEmpty && subtitles.isEmpty;

  List<Object?> toJson() => [
    for (final t in [...video, ...audio, ...subtitles]) t.toJson(),
  ];

  static MediaTracks? fromJson(Object? j) =>
      j is List ? MediaTracks.of([for (final t in j) ?MediaTrack.fromJson(t)]) : null;

  factory MediaTracks.of(List<MediaTrack> tracks) => MediaTracks(
    video: tracks.where((t) => t.kind == MediaTrackKind.video).toList(),
    audio: tracks.where((t) => t.kind == MediaTrackKind.audio).toList(),
    subtitles: tracks.where((t) => t.kind == MediaTrackKind.subtitle).toList(),
  );
}

/// Names a file the same way for every user, so one person's read of its
/// tracks serves everyone: its exact size and its name. Null when the size is
/// unknown, since a name alone could match a different cut.
String? fileKey(StremioStream s) {
  final size = s.sizeBytes;
  if (size == null || size <= 0) return null;
  final name =
      s.filename ??
      streamDetails(s).where((d) => d.kind == StreamDetailKind.file).map((d) => d.text).firstOrNull ??
      Uri.tryParse(s.url)?.pathSegments.lastOrNull;
  if (name == null || name.trim().isEmpty) return null;
  return 'f:$size:${name.trim()}';
}

extension MediaTracksShared on MediaTracks {
  List<FileTrack> toShared() => [
    for (final t in [...video, ...audio, ...subtitles])
      FileTrack(
        kind: t.kind.name,
        index: t.index,
        codec: t.codec,
        language: t.language,
        name: t.name,
        channels: t.channels,
        width: t.width,
        height: t.height,
        isDefault: t.isDefault,
        isForced: t.isForced,
      ),
  ];

  static MediaTracks? fromShared(List<FileTrack>? tracks) {
    if (tracks == null) return null;
    final out = <MediaTrack>[];
    for (final t in tracks) {
      final kind = MediaTrackKind.values.where((k) => k.name == t.kind).firstOrNull;
      if (kind == null) continue;
      out.add(
        MediaTrack(
          kind: kind,
          index: t.index,
          codec: t.codec,
          language: t.language,
          name: t.name,
          channels: t.channels,
          width: t.width,
          height: t.height,
          isDefault: t.isDefault,
          isForced: t.isForced,
        ),
      );
    }
    final m = MediaTracks.of(out);
    return m.isEmpty ? null : m;
  }
}

/// "5.1" for 6 channels, "Stereo" for 2.
String? channelLabel(int? channels) => switch (channels) {
  null || <= 0 => null,
  1 => 'Mono',
  2 => 'Stereo',
  3 => '2.1',
  6 => '5.1',
  7 => '6.1',
  8 => '7.1',
  _ => '$channels ch',
};

/// Reads `length` bytes at `offset`, or fewer at the end of the file.
typedef RangeReader = Future<Uint8List> Function(int offset, int length);

/// The first 256 KB hold the track list of nearly every MKV and of MP4s
/// written for streaming; anything else costs one or two more small reads.
const _headBytes = 256 * 1024;

/// The most the probe reads for one MP4 `moov` box or Matroska `Tracks`.
const _maxBox = 8 * 1024 * 1024;

/// Lists a stream's audio, subtitle and video tracks by reading only the start
/// of the file (and, for an MP4 with its index at the end, that index), so the
/// details page can show them before playing. Null when the file isn't MKV,
/// WebM or MP4, the server doesn't support ranges, or anything fails.
Future<MediaTracks?> probeStream(
  StremioStream stream, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final c = client ?? http.Client();
  try {
    final reader = cachedReader(httpRangeReader(c, Uri.parse(stream.url), stream.headers));
    return await probeTracks(reader).timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// A [RangeReader] over HTTP Range requests. It reads only the bytes asked
/// for, even when a server ignores the range and starts sending the whole file.
RangeReader httpRangeReader(http.Client client, Uri url, Map<String, String> headers) {
  return (offset, length) async {
    final request = http.Request('GET', url)
      ..headers.addAll(headers)
      ..headers['range'] = 'bytes=$offset-${offset + length - 1}';
    final response = await client.send(request);
    if (response.statusCode != 206 && !(response.statusCode == 200 && offset == 0)) {
      unawaited(response.stream.listen(null).cancel());
      throw http.ClientException('No range support (${response.statusCode})', url);
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      out.add(chunk);
      if (out.length >= length) break;
    }
    final bytes = out.takeBytes();
    return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
  };
}

/// Serves reads inside the file's first [_headBytes] from one request.
RangeReader cachedReader(RangeReader inner) {
  Future<Uint8List>? head;
  return (offset, length) async {
    if (offset + length <= _headBytes) {
      final h = await (head ??= inner(0, _headBytes));
      if (offset >= h.length) return Uint8List(0);
      return Uint8List.sublistView(h, offset, (offset + length).clamp(0, h.length));
    }
    return inner(offset, length);
  };
}

/// The tracks of an MKV, WebM or MP4 read through [read], or null for other
/// formats and files whose track list can't be found.
Future<MediaTracks?> probeTracks(RangeReader read) async {
  final start = await read(0, 12);
  if (start.length < 8) return null;
  if (start[0] == 0x1A && start[1] == 0x45 && start[2] == 0xDF && start[3] == 0xA3) return _probeMatroska(read);
  if (String.fromCharCodes(start.sublist(4, 8)) == 'ftyp') return _probeMp4(read);
  return null;
}

// --- Matroska ---------------------------------------------------------------

const _ebmlSegment = 0x18538067;
const _ebmlSeekHead = 0x114D9B74;
const _ebmlSeek = 0x4DBB;
const _ebmlSeekId = 0x53AB;
const _ebmlSeekPosition = 0x53AC;
const _ebmlTracks = 0x1654AE6B;
const _ebmlCluster = 0x1F43B675;
const _ebmlTrackEntry = 0xAE;
const _ebmlTrackType = 0x83;
const _ebmlCodecId = 0x86;
const _ebmlName = 0x536E;
const _ebmlLanguage = 0x22B59C;
const _ebmlLanguageBcp47 = 0x22B59D;
const _ebmlFlagDefault = 0x88;
const _ebmlFlagForced = 0x55AA;
const _ebmlVideo = 0xE0;
const _ebmlPixelWidth = 0xB0;
const _ebmlPixelHeight = 0xBA;
const _ebmlAudio = 0xE1;
const _ebmlChannels = 0x9F;

/// An element header: its id, where its data starts, and its size (null when
/// the size is "unknown", as in live-written files).
typedef _Element = ({int id, int dataStart, int? size});

/// Reads an EBML variable-length integer at [pos]; returns (value, length).
/// [keepMarker] keeps the length bits, as element ids do.
(int, int)? _vint(Uint8List b, int pos, {bool keepMarker = false}) {
  if (pos >= b.length) return null;
  final first = b[pos];
  var len = 1;
  var mask = 0x80;
  while (len <= 8 && (first & mask) == 0) {
    len++;
    mask >>= 1;
  }
  if (len > 8 || pos + len > b.length) return null;
  var value = keepMarker ? first : first & (mask - 1);
  var allOnes = (first & (mask - 1)) == mask - 1;
  for (var i = 1; i < len; i++) {
    value = (value << 8) | b[pos + i];
    if (b[pos + i] != 0xFF) allOnes = false;
  }
  return (allOnes && !keepMarker ? -1 : value, len);
}

_Element? _element(Uint8List b, int pos) {
  final id = _vint(b, pos, keepMarker: true);
  if (id == null || id.$2 > 4) return null;
  final size = _vint(b, pos + id.$2);
  if (size == null) return null;
  return (id: id.$1, dataStart: pos + id.$2 + size.$2, size: size.$1 < 0 ? null : size.$1);
}

/// The child elements of `b[start, end)`.
Iterable<_Element> _children(Uint8List b, int start, int end) sync* {
  var pos = start;
  while (pos < end) {
    final e = _element(b, pos);
    if (e == null || e.size == null) return;
    yield e;
    pos = e.dataStart + e.size!;
  }
}

int _uint(Uint8List b, _Element e) {
  var v = 0;
  for (var i = 0; i < e.size! && i < 8; i++) {
    v = (v << 8) | b[e.dataStart + i];
  }
  return v;
}

String _text(Uint8List b, _Element e) {
  final bytes = Uint8List.sublistView(b, e.dataStart, e.dataStart + e.size!);
  final nul = bytes.indexOf(0);
  return utf8.decode(nul < 0 ? bytes : Uint8List.sublistView(bytes, 0, nul), allowMalformed: true);
}

Future<MediaTracks?> _probeMatroska(RangeReader read) async {
  final head = await read(0, _headBytes);
  final ebml = _element(head, 0);
  if (ebml == null || ebml.size == null) return null;
  final segment = _element(head, ebml.dataStart + ebml.size!);
  if (segment == null || segment.id != _ebmlSegment) return null;
  final segStart = segment.dataStart;

  int? tracksAt;
  var pos = segStart;
  while (pos < head.length) {
    final e = _element(head, pos);
    if (e == null || e.size == null || e.id == _ebmlCluster) break;
    if (e.id == _ebmlTracks) {
      final end = e.dataStart + e.size!;
      if (end <= head.length) return _matroskaTracks(head, e.dataStart, end);
      tracksAt = pos;
      break;
    }
    if (e.id == _ebmlSeekHead && e.dataStart + e.size! <= head.length) {
      for (final seek in _children(head, e.dataStart, e.dataStart + e.size!)) {
        if (seek.id != _ebmlSeek) continue;
        int? id, at;
        for (final f in _children(head, seek.dataStart, seek.dataStart + seek.size!)) {
          if (f.id == _ebmlSeekId) id = _uint(head, f);
          if (f.id == _ebmlSeekPosition) at = _uint(head, f);
        }
        if (id == _ebmlTracks && at != null) tracksAt ??= segStart + at;
      }
    }
    pos = e.dataStart + e.size!;
  }
  if (tracksAt == null) return null;

  // Tracks outside the first read: its header, then the whole element.
  final top = await read(tracksAt, 16);
  final e = _element(top, 0);
  if (e == null || e.id != _ebmlTracks || e.size == null || e.size! > _maxBox) return null;
  final body = await read(tracksAt, e.dataStart + e.size!);
  if (body.length < e.dataStart + e.size!) return null;
  return _matroskaTracks(body, e.dataStart, e.dataStart + e.size!);
}

MediaTracks _matroskaTracks(Uint8List b, int start, int end) {
  final out = <MediaTrack>[];
  final counts = {for (final k in MediaTrackKind.values) k: 0};
  for (final entry in _children(b, start, end)) {
    if (entry.id != _ebmlTrackEntry) continue;
    int? type, channels, width, height;
    String? codec, name, language, bcp47;
    var isDefault = true, isForced = false;
    for (final f in _children(b, entry.dataStart, entry.dataStart + entry.size!)) {
      switch (f.id) {
        case _ebmlTrackType:
          type = _uint(b, f);
        case _ebmlCodecId:
          codec = _text(b, f);
        case _ebmlName:
          name = _text(b, f);
        case _ebmlLanguage:
          language = _text(b, f);
        case _ebmlLanguageBcp47:
          bcp47 = _text(b, f);
        case _ebmlFlagDefault:
          isDefault = _uint(b, f) != 0;
        case _ebmlFlagForced:
          isForced = _uint(b, f) != 0;
        case _ebmlAudio:
          for (final a in _children(b, f.dataStart, f.dataStart + f.size!)) {
            if (a.id == _ebmlChannels) channels = _uint(b, a);
          }
        case _ebmlVideo:
          for (final v in _children(b, f.dataStart, f.dataStart + f.size!)) {
            if (v.id == _ebmlPixelWidth) width = _uint(b, v);
            if (v.id == _ebmlPixelHeight) height = _uint(b, v);
          }
      }
    }
    final kind = switch (type) {
      1 => MediaTrackKind.video,
      2 => MediaTrackKind.audio,
      17 => MediaTrackKind.subtitle,
      _ => null,
    };
    if (kind == null) continue;
    counts[kind] = counts[kind]! + 1;
    final lang = bcp47 ?? language;
    out.add(
      MediaTrack(
        kind: kind,
        index: counts[kind]!,
        codec: codec == null ? null : (_mkvCodecs[codec] ?? _mkvCodecPrefix(codec)),
        language: lang == null || lang == 'und' || lang.isEmpty ? null : lang,
        name: name == null || name.trim().isEmpty ? null : name.trim(),
        channels: kind == MediaTrackKind.audio ? (channels ?? 1) : null,
        width: width,
        height: height,
        isDefault: isDefault,
        isForced: isForced,
      ),
    );
  }
  return MediaTracks.of(out);
}

const _mkvCodecs = {
  'V_MPEG4/ISO/AVC': 'H.264',
  'V_MPEGH/ISO/HEVC': 'HEVC',
  'V_AV1': 'AV1',
  'V_VP9': 'VP9',
  'V_VP8': 'VP8',
  'V_MPEG2': 'MPEG-2',
  'A_AC3': 'AC3',
  'A_EAC3': 'E-AC3',
  'A_DTS': 'DTS',
  'A_TRUEHD': 'TrueHD',
  'A_OPUS': 'Opus',
  'A_FLAC': 'FLAC',
  'A_VORBIS': 'Vorbis',
  'A_MPEG/L3': 'MP3',
  'A_MPEG/L2': 'MP2',
  'S_TEXT/UTF8': 'SRT',
  'S_TEXT/ASS': 'ASS',
  'S_TEXT/SSA': 'SSA',
  'S_ASS': 'ASS',
  'S_SSA': 'SSA',
  'S_TEXT/WEBVTT': 'WebVTT',
  'S_HDMV/PGS': 'PGS',
  'S_VOBSUB': 'VobSub',
  'S_DVBSUB': 'DVB',
};

String _mkvCodecPrefix(String id) {
  if (id.startsWith('A_AAC')) return 'AAC';
  if (id.startsWith('A_PCM')) return 'PCM';
  if (id.startsWith('A_DTS')) return 'DTS';
  return id.replaceFirst(RegExp('^[VAS]_'), '');
}

// --- MP4 --------------------------------------------------------------------

typedef _Box = ({String type, int dataStart, int end});

_Box? _box(Uint8List b, int pos, int limit) {
  if (pos + 8 > limit) return null;
  final d = ByteData.sublistView(b);
  var size = d.getUint32(pos);
  final type = String.fromCharCodes(b.sublist(pos + 4, pos + 8));
  var header = 8;
  if (size == 1) {
    if (pos + 16 > limit) return null;
    size = d.getUint32(pos + 8) * 0x100000000 + d.getUint32(pos + 12);
    header = 16;
  } else if (size == 0) {
    size = limit - pos;
  }
  if (size < header) return null;
  return (type: type, dataStart: pos + header, end: pos + size);
}

Iterable<_Box> _boxes(Uint8List b, int start, int end) sync* {
  var pos = start;
  while (pos < end) {
    final box = _box(b, pos, end);
    if (box == null || box.end > end) return;
    yield box;
    pos = box.end;
  }
}

_Box? _find(Uint8List b, _Box parent, String type) {
  for (final c in _boxes(b, parent.dataStart, parent.end)) {
    if (c.type == type) return c;
  }
  return null;
}

Future<MediaTracks?> _probeMp4(RangeReader read) async {
  // Walk the top-level boxes until `moov`: usually right after `ftyp`, or
  // after `mdat` in files that weren't prepared for streaming.
  var pos = 0;
  for (var i = 0; i < 16; i++) {
    final h = await read(pos, 16);
    if (h.length < 8) return null;
    final d = ByteData.sublistView(h);
    var size = d.getUint32(0);
    final type = String.fromCharCodes(h.sublist(4, 8));
    if (size == 1) {
      if (h.length < 16) return null;
      size = d.getUint32(8) * 0x100000000 + d.getUint32(12);
    }
    if (type == 'moov') {
      if (size == 0 || size > _maxBox) return null;
      final moov = await read(pos, size);
      if (moov.length < size) return null;
      return _mp4Tracks(moov);
    }
    if (size < 8) return null;
    pos += size;
  }
  return null;
}

MediaTracks _mp4Tracks(Uint8List b) {
  final moov = _box(b, 0, b.length)!;
  final out = <MediaTrack>[];
  final counts = {for (final k in MediaTrackKind.values) k: 0};
  final d = ByteData.sublistView(b);
  for (final trak in _boxes(b, moov.dataStart, moov.end)) {
    if (trak.type != 'trak') continue;
    final mdia = _find(b, trak, 'mdia');
    if (mdia == null) continue;
    final hdlr = _find(b, mdia, 'hdlr');
    if (hdlr == null || hdlr.dataStart + 12 > hdlr.end) continue;
    final handler = String.fromCharCodes(b.sublist(hdlr.dataStart + 8, hdlr.dataStart + 12));
    final kind = switch (handler) {
      'vide' => MediaTrackKind.video,
      'soun' => MediaTrackKind.audio,
      'sbtl' || 'subt' || 'text' || 'clcp' => MediaTrackKind.subtitle,
      _ => null,
    };
    if (kind == null) continue;

    String? language;
    final mdhd = _find(b, mdia, 'mdhd');
    if (mdhd != null) {
      final at = mdhd.dataStart + (b[mdhd.dataStart] == 1 ? 32 : 20);
      if (at + 2 <= mdhd.end) {
        final packed = d.getUint16(at);
        final code = String.fromCharCodes([
          ((packed >> 10) & 0x1F) + 0x60,
          ((packed >> 5) & 0x1F) + 0x60,
          (packed & 0x1F) + 0x60,
        ]);
        if (packed != 0 && code != 'und' && RegExp(r'^[a-z]{3}$').hasMatch(code)) language = code;
      }
    }

    var isDefault = true;
    final tkhd = _find(b, trak, 'tkhd');
    int? width, height;
    if (tkhd != null && tkhd.dataStart + 4 <= tkhd.end) {
      isDefault = (b[tkhd.dataStart + 3] & 0x1) != 0;
      // Width and height close the box, as 16.16 fixed point.
      if (kind == MediaTrackKind.video && tkhd.end - 8 > tkhd.dataStart) {
        width = d.getUint32(tkhd.end - 8) >> 16;
        height = d.getUint32(tkhd.end - 4) >> 16;
        if (width == 0 || height == 0) width = height = null;
      }
    }

    String? codec;
    int? channels;
    final stsd = ['minf', 'stbl', 'stsd'].fold<_Box?>(mdia, (box, type) => box == null ? null : _find(b, box, type));
    if (stsd != null && stsd.dataStart + 16 <= stsd.end) {
      final entry = stsd.dataStart + 8;
      final fourcc = String.fromCharCodes(b.sublist(entry + 4, entry + 8));
      codec = _mp4Codecs[fourcc] ?? fourcc.trim();
      if (kind == MediaTrackKind.audio && entry + 26 <= stsd.end) channels = d.getUint16(entry + 24);
    }

    counts[kind] = counts[kind]! + 1;
    out.add(
      MediaTrack(
        kind: kind,
        index: counts[kind]!,
        codec: codec,
        language: language,
        channels: channels,
        width: width,
        height: height,
        isDefault: isDefault,
      ),
    );
  }
  return MediaTracks.of(out);
}

const _mp4Codecs = {
  'avc1': 'H.264',
  'avc3': 'H.264',
  'hvc1': 'HEVC',
  'hev1': 'HEVC',
  'dvh1': 'Dolby Vision',
  'dvhe': 'Dolby Vision',
  'av01': 'AV1',
  'vp09': 'VP9',
  'mp4a': 'AAC',
  'ac-3': 'AC3',
  'ec-3': 'E-AC3',
  'Opus': 'Opus',
  'fLaC': 'FLAC',
  '.mp3': 'MP3',
  'tx3g': 'Text',
  'wvtt': 'WebVTT',
  'stpp': 'TTML',
  'c608': 'CEA-608',
};
