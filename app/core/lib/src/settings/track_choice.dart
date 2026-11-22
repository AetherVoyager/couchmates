import '../stremio/media_probe.dart';
import 'app_settings.dart';

/// A track as the player reports it, reduced to what choosing needs.
class TrackInfo {
  const TrackInfo({required this.id, this.language, this.title, this.forced = false, this.isDefault = false});

  final String id;
  final String? language;
  final String? title;
  final bool forced;
  final bool isDefault;
}

/// mpv reports ISO 639-2 codes (`eng`) or 639-1 (`en`); settings use 639-1.
const _iso639_2to1 = {
  'eng': 'en',
  'mal': 'ml',
  'hin': 'hi',
  'tam': 'ta',
  'tel': 'te',
  'kan': 'kn',
  'ben': 'bn',
  'mar': 'mr',
  'urd': 'ur',
  'spa': 'es',
  'fre': 'fr',
  'fra': 'fr',
  'ger': 'de',
  'deu': 'de',
  'ita': 'it',
  'por': 'pt',
  'rus': 'ru',
  'jpn': 'ja',
  'kor': 'ko',
  'chi': 'zh',
  'zho': 'zh',
  'ara': 'ar',
  'tur': 'tr',
  'dut': 'nl',
  'nld': 'nl',
  'pol': 'pl',
  'swe': 'sv',
  'nor': 'no',
  'dan': 'da',
  'fin': 'fi',
  'ind': 'id',
  'tha': 'th',
  'vie': 'vi',
  'heb': 'he',
  'gre': 'el',
  'ell': 'el',
  'ukr': 'uk',
  'per': 'fa',
  'fas': 'fa',
  'may': 'ms',
  'msa': 'ms',
  'fil': 'tl',
  'tgl': 'tl',
};

/// [code] as a two-letter language code where one exists.
String normalizeLanguage(String? code) {
  final c = (code ?? '').trim().toLowerCase().split(RegExp('[-_]')).first;
  return _iso639_2to1[c] ?? c;
}

int _rank(TrackInfo t, List<String> preferred) {
  final i = preferred.indexOf(normalizeLanguage(t.language));
  return i < 0 ? preferred.length : i;
}

/// The audio track to switch to, or null to keep the file's default.
String? chooseAudio(List<TrackInfo> tracks, List<String> preferred) {
  if (preferred.isEmpty || tracks.isEmpty) return null;
  final best = [...tracks]..sort((a, b) => _rank(a, preferred).compareTo(_rank(b, preferred)));
  return _rank(best.first, preferred) < preferred.length ? best.first.id : null;
}

/// The subtitle track to show: an id, `'no'` to turn subtitles off, or null
/// to leave the file's own choice.
String? chooseSubtitle(
  List<TrackInfo> subtitles, {
  required SubtitleMode mode,
  required List<String> preferredSubtitles,
  required List<String> preferredAudio,
  required String? audioLanguage,
}) {
  if (mode == SubtitleMode.off) return 'no';
  if (subtitles.isEmpty) return null;
  final wanted = preferredSubtitles.isNotEmpty ? preferredSubtitles : preferredAudio;
  final inWanted = [...subtitles.where((t) => _rank(t, wanted) < wanted.length)]
    ..sort((a, b) {
      final r = _rank(a, wanted).compareTo(_rank(b, wanted));
      if (r != 0) return r;
      // Full subtitles before forced ones when showing them for a language.
      return (a.forced ? 1 : 0).compareTo(b.forced ? 1 : 0);
    });
  if (mode == SubtitleMode.always) return inWanted.isEmpty ? null : inWanted.first.id;

  // Auto: subtitles when the audio isn't in a language the user understands;
  // otherwise only forced ones (signs, foreign dialogue) in their language.
  final understood = {...preferredAudio, ...preferredSubtitles};
  final audio = normalizeLanguage(audioLanguage);
  final understandsAudio = understood.isEmpty || audio.isEmpty || understood.contains(audio);
  if (!understandsAudio) return inWanted.isEmpty ? null : inWanted.first.id;
  final forced = subtitles.where((t) => t.forced && (audio.isEmpty || normalizeLanguage(t.language) == audio));
  return forced.isEmpty ? 'no' : forced.first.id;
}

/// The audio and subtitle tracks the player will pick for [t] with these
/// settings, as [MediaTrack.index] values; subtitle 0 means none. This is
/// what the details page shows before anything is changed.
({int? audio, int subtitle}) expectedTracks(MediaTracks t, AppSettings s) {
  TrackInfo info(MediaTrack m) =>
      TrackInfo(id: '${m.index}', language: m.language, title: m.name, forced: m.isForced, isDefault: m.isDefault);
  final picked = chooseAudio([for (final a in t.audio) info(a)], s.audioLanguages);
  final fileDefault = t.audio.where((a) => a.isDefault).firstOrNull ?? t.audio.firstOrNull;
  final audio = picked == null ? fileDefault : t.audio.firstWhere((a) => '${a.index}' == picked);
  final sub = chooseSubtitle(
    [for (final x in t.subtitles) info(x)],
    mode: s.subtitleMode,
    preferredSubtitles: s.subtitleLanguages,
    preferredAudio: s.audioLanguages,
    audioLanguage: audio?.language,
  );
  final int subtitle;
  if (sub == 'no' || t.subtitles.isEmpty) {
    subtitle = 0;
  } else if (sub != null) {
    subtitle = int.parse(sub);
  } else {
    // The file's own choice: its default subtitle track, if it marks one.
    subtitle = t.subtitles.where((x) => x.isDefault && x.isForced == false).firstOrNull?.index ?? 0;
  }
  return (audio: audio?.index, subtitle: subtitle);
}
