import 'models.dart';

/// What a line of a stream's description is about.
enum StreamDetailKind { file, size, video, audio, language, source, other }

class StreamDetail {
  const StreamDetail(this.kind, this.text);

  final StreamDetailKind kind;
  final String text;
}

const _markers = {
  '📁': StreamDetailKind.file,
  '💾': StreamDetailKind.size,
  '📦': StreamDetailKind.size,
  '🎥': StreamDetailKind.video,
  '🎞': StreamDetailKind.video,
  '📺': StreamDetailKind.video,
  '🔊': StreamDetailKind.audio,
  '🎧': StreamDetailKind.audio,
  '🌐': StreamDetailKind.language,
  '🗣': StreamDetailKind.language,
  '📡': StreamDetailKind.source,
};

/// The facts in a stream's description, the way Telegram-Stremio writes them:
/// one line per fact, each starting with an emoji (`📁 file.mkv`, `💾 1.5 GB`,
/// `🎥 x265 🔊 AAC 5.1`). Lines with several markers are split up.
List<StreamDetail> streamDetails(StremioStream s) {
  final out = <StreamDetail>[];
  for (final raw in (s.title ?? '').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    // Split at every marker so "🎥 x265 🔊 AAC" gives a video and an audio fact.
    final pieces = <(StreamDetailKind, String)>[];
    var kind = StreamDetailKind.other;
    final buf = StringBuffer();
    for (final rune in line.runes) {
      final ch = String.fromCharCode(rune);
      final marker = _markers[ch];
      if (marker != null) {
        if (buf.toString().trim().isNotEmpty) pieces.add((kind, buf.toString().trim()));
        buf.clear();
        kind = marker;
      } else if (rune != 0xFE0F) {
        buf.write(ch);
      }
    }
    if (buf.toString().trim().isNotEmpty) pieces.add((kind, buf.toString().trim()));
    for (final (k, t) in pieces) {
      out.add(StreamDetail(k, t));
    }
  }
  if (s.sizeBytes != null && !out.any((d) => d.kind == StreamDetailKind.size)) {
    out.add(StreamDetail(StreamDetailKind.size, formatBytes(s.sizeBytes!)));
  }
  if (s.filename != null && !out.any((d) => d.kind == StreamDetailKind.file)) {
    out.insert(0, StreamDetail(StreamDetailKind.file, s.filename!));
  }
  return out;
}

String formatBytes(int bytes) {
  const gb = 1 << 30, mb = 1 << 20;
  return bytes >= gb ? '${(bytes / gb).toStringAsFixed(1)} GB' : '${(bytes / mb).round()} MB';
}
