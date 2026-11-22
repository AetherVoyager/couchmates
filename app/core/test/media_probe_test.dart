import 'dart:convert';
import 'dart:typed_data';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// --- tiny EBML writer ---

List<int> _id(int id) {
  final out = <int>[];
  for (var v = id; v > 0; v >>= 8) {
    out.insert(0, v & 0xFF);
  }
  return out;
}

List<int> _size(int n) => [0x01, for (var i = 6; i >= 0; i--) (n >> (8 * i)) & 0xFF]; // 8-byte vint

List<int> el(int id, List<int> data) => [..._id(id), ..._size(data.length), ...data];
List<int> uint(int id, int v) => el(id, [v]);
List<int> str(int id, String s) => el(id, utf8.encode(s));

List<int> track({
  required int type,
  required String codec,
  String? lang,
  String? name,
  int? channels,
  bool? isDefault,
  bool forced = false,
}) => el(0xAE, [
  ...uint(0xD7, 1),
  ...uint(0x83, type),
  ...str(0x86, codec),
  if (lang != null) ...str(0x22B59C, lang),
  if (name != null) ...str(0x536E, name),
  if (isDefault != null) ...uint(0x88, isDefault ? 1 : 0),
  if (forced) ...uint(0x55AA, 1),
  if (channels != null) ...el(0xE1, uint(0x9F, channels)),
  if (type == 1)
    ...el(0xE0, [
      ...el(0xB0, [0x07, 0x80]),
      ...el(0xBA, [0x04, 0x38]),
    ]),
]);

Uint8List mkv(List<int> segmentChildren) =>
    Uint8List.fromList([...el(0x1A45DFA3, str(0x4282, 'matroska')), ...el(0x18538067, segmentChildren)]);

List<int> sampleTracks() => el(0x1654AE6B, [
  ...track(type: 1, codec: 'V_MPEGH/ISO/HEVC'),
  ...track(type: 2, codec: 'A_EAC3', lang: 'mal', name: 'Malayalam DD+ 5.1', channels: 6),
  ...track(type: 2, codec: 'A_AAC/MPEG4/LC', lang: 'eng', channels: 2, isDefault: false),
  ...track(type: 17, codec: 'S_TEXT/UTF8', lang: 'eng', name: 'English'),
  ...track(type: 17, codec: 'S_HDMV/PGS', lang: 'eng', forced: true, name: 'Forced'),
]);

RangeReader memory(Uint8List file) => (offset, length) async {
  if (offset >= file.length) return Uint8List(0);
  return Uint8List.sublistView(file, offset, (offset + length).clamp(0, file.length));
};

// --- tiny MP4 writer ---

List<int> u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> box(String type, List<int> data) => [...u32(data.length + 8), ...ascii.encode(type), ...data];

int packLang(String l) => ((l.codeUnitAt(0) - 0x60) << 10) | ((l.codeUnitAt(1) - 0x60) << 5) | (l.codeUnitAt(2) - 0x60);

List<int> trak(String handler, String fourcc, String lang, {int channels = 2}) => box('trak', [
  ...box('tkhd', [0, 0, 0, 1, ...List.filled(72, 0), ...u32(1280 << 16), ...u32(720 << 16)]),
  ...box('mdia', [
    ...box('mdhd', [0, 0, 0, 0, ...List.filled(16, 0), ...u16(packLang(lang)), 0, 0]),
    ...box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...ascii.encode(handler), ...List.filled(12, 0), 0]),
    ...box(
      'minf',
      box(
        'stbl',
        box('stsd', [
          0, 0, 0, 0, ...u32(1), //
          ...box(fourcc, [...List.filled(16, 0), ...u16(channels), ...u16(16), ...List.filled(8, 0)]),
        ]),
      ),
    ),
  ]),
]);

List<int> moov() => box('moov', [
  ...trak('vide', 'avc1', 'und'),
  ...trak('soun', 'mp4a', 'eng', channels: 6),
  ...trak('soun', 'ac-3', 'hin'),
  ...trak('sbtl', 'tx3g', 'eng'),
]);

void main() {
  test('reads audio and subtitle tracks from an MKV', () async {
    final t = await probeTracks(memory(mkv([...el(0x1549A966, uint(0x2AD7B1, 1)), ...sampleTracks()])));
    expect(t, isNotNull);
    expect(t!.video.single.codec, 'HEVC');
    expect(t.video.single.width, 1920);
    expect(t.audio.map((a) => a.index), [1, 2]);
    expect(t.audio.first.language, 'mal');
    expect(t.audio.first.codec, 'E-AC3');
    expect(t.audio.first.name, 'Malayalam DD+ 5.1');
    expect(channelLabel(t.audio.first.channels), '5.1');
    expect(t.audio.first.isDefault, isTrue);
    expect(t.audio.last.isDefault, isFalse);
    expect(t.audio.last.codec, 'AAC');
    expect(t.subtitles.map((s) => s.codec), ['SRT', 'PGS']);
    expect(t.subtitles.last.isForced, isTrue);
  });

  test('follows the SeekHead to Tracks past the first read', () async {
    final filler = el(0xEC, List.filled(300 * 1024, 0)); // Void element
    final tracks = sampleTracks();
    // SeekPosition is relative to the segment's data: SeekHead + filler come first.
    List<int> seekHead(int at) => el(0x114D9B74, el(0x4DBB, [...el(0x53AB, u32(0x1654AE6B)), ...el(0x53AC, u32(at))]));
    final headLen = seekHead(0).length;
    final file = mkv([...seekHead(headLen + filler.length), ...filler, ...tracks]);
    final t = await probeTracks(cachedReader(memory(file)));
    expect(t!.audio.length, 2);
    expect(t.subtitles.length, 2);
  });

  test('reads an MP4 with moov first', () async {
    final file = Uint8List.fromList([
      ...box('ftyp', ascii.encode('isom0000')),
      ...moov(),
      ...box('mdat', [1, 2, 3]),
    ]);
    final t = await probeTracks(memory(file));
    expect(t!.video.single.codec, 'H.264');
    expect(t.video.single.language, isNull);
    expect((t.video.single.width, t.video.single.height), (1280, 720));
    expect(t.audio.map((a) => (a.language, a.codec, a.channels)), [('eng', 'AAC', 6), ('hin', 'AC3', 2)]);
    expect(t.subtitles.single.language, 'eng');
  });

  test('reads an MP4 with moov after mdat', () async {
    final file = Uint8List.fromList([
      ...box('ftyp', ascii.encode('isom0000')),
      ...box('mdat', List.filled(400 * 1024, 0)),
      ...moov(),
    ]);
    final t = await probeTracks(cachedReader(memory(file)));
    expect(t!.audio.length, 2);
  });

  test('gives up on other formats', () async {
    expect(await probeTracks(memory(Uint8List.fromList(List.filled(64, 7)))), isNull);
  });

  test('probeStream sends ranges and handles servers without them', () async {
    final file = mkv(sampleTracks());
    final ranges = <String?>[];
    final ok = MockClient((r) async {
      ranges.add(r.headers['range']);
      expect(r.headers['x-token'], 'abc');
      return http.Response.bytes(file, 206);
    });
    const stream = StremioStream(url: 'https://example.com/v.mkv', headers: {'x-token': 'abc'});
    final t = await probeStream(stream, client: ok);
    expect(t!.audio.length, 2);
    expect(ranges.single, 'bytes=0-${256 * 1024 - 1}');

    final none = MockClient((r) async => http.Response('nope', 404));
    expect(await probeStream(stream, client: none), isNull);
  });

  test('tracks survive a JSON round trip', () async {
    final t = (await probeTracks(memory(mkv(sampleTracks()))))!;
    final back = MediaTracks.fromJson(jsonDecode(jsonEncode(t.toJson())))!;
    expect(back.toJson(), t.toJson());
    expect(back.audio.length, t.audio.length);
    expect(MediaTracks.fromJson('junk'), isNull);
  });

  test('file keys use the size and name, and need the size', () {
    expect(
      fileKey(const StremioStream(url: 'https://x/a/b.mkv?t=1', sizeBytes: 42, filename: 'Movie.mkv')),
      'f:42:Movie.mkv',
    );
    expect(fileKey(const StremioStream(url: 'https://x/a/b.mkv?t=1', sizeBytes: 42)), 'f:42:b.mkv');
    expect(fileKey(const StremioStream(url: 'https://x/a/b.mkv', filename: 'Movie.mkv')), isNull);
  });

  test('tracks convert to the shared shape and back', () async {
    final t = (await probeTracks(memory(mkv(sampleTracks()))))!;
    final back = MediaTracksShared.fromShared(t.toShared())!;
    expect(back.toJson(), t.toJson());
    expect(MediaTracksShared.fromShared(null), isNull);
    expect(MediaTracksShared.fromShared(const [FileTrack(kind: 'data', index: 1)]), isNull);
  });
}
