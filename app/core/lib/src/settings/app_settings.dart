import 'package:flutter/foundation.dart';

/// Where [AppSettings] keeps its values. The app uses its preferences file;
/// tests keep them in memory.
abstract interface class SettingsStore {
  Future<Map<String, Object>> load();
  Future<void> write(String key, Object? value);
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([Map<String, Object>? values]) : values = {...?values};

  final Map<String, Object> values;

  @override
  Future<Map<String, Object>> load() async => Map.of(values);

  @override
  Future<void> write(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// One setting: its storage key and default. Values are bool, int, double
/// or String, as the preferences file stores them.
class Setting<T extends Object> {
  const Setting(this.key, this.defaultValue, {this.choices});

  final String key;
  final T defaultValue;

  /// The allowed values, for settings picked from a list. A stored value
  /// outside them falls back to [defaultValue].
  final List<T>? choices;
}

enum ThemeChoice { dark, black, light, system }

enum PosterSize { small, medium, large }

enum SubtitleMode {
  /// Never turn subtitles on by themselves.
  off,

  /// Turn them on when the audio isn't in a preferred language, or the
  /// subtitle track is forced.
  auto,

  /// Always pick a subtitle track in a preferred language.
  always,
}

/// Every setting the app has, by section.
abstract final class Settings {
  // Appearance
  static const theme = Setting<String>('appearance.theme', 'dark');
  static const accent = Setting<int>('appearance.accent', 0xFF7C9CFF);
  static const posterSize = Setting<String>('appearance.poster_size', 'medium');

  // Friends
  /// Let others on the Hub see what this device plays (and ask to join).
  static const shareActivity = Setting<bool>('social.share_activity', true);

  /// Show the floating "who's watching" bubble.
  static const showBubble = Setting<bool>('social.show_bubble', true);

  /// Show the bubble over the player too (with its controls).
  static const bubbleInPlayer = Setting<bool>('social.bubble_in_player', true);

  // Video playback
  static const hardwareDecoding = Setting<bool>('playback.hardware_decoding', true);

  /// ISO 639 codes, most preferred first, comma-separated, such as `en,ml`.
  static const audioLanguages = Setting<String>('playback.audio_languages', '');
  static const subtitleLanguages = Setting<String>('playback.subtitle_languages', '');
  static const subtitleMode = Setting<String>('playback.subtitle_mode', 'auto');

  /// Offer subtitles from OpenSubtitles (Stremio's addon) in the player, and
  /// load one when the file has none in the wanted language.
  static const onlineSubtitles = Setting<bool>('playback.online_subtitles', true);

  /// Percent of the default subtitle size.
  static const subtitleSize = Setting<int>('playback.subtitle_size', 100, choices: [70, 85, 100, 120, 140, 170]);
  static const defaultVolume = Setting<int>('playback.volume', 100, choices: [25, 50, 75, 100]);
  static const resume = Setting<bool>('playback.resume', true);
  static const autoplayNext = Setting<bool>('playback.autoplay_next', true);

  // Player controls
  static const seekBack = Setting<int>('controls.seek_back', 10, choices: [5, 10, 15, 30]);
  static const seekForward = Setting<int>('controls.seek_forward', 30, choices: [10, 15, 30, 60, 90]);
  static const hideAfter = Setting<int>('controls.hide_after', 3, choices: [2, 3, 5, 8]);
  static const doubleClickFullscreen = Setting<bool>('controls.double_click_fullscreen', true);

  // Updates
  static const checkUpdates = Setting<bool>('updates.check', true);

  // Voice chat
  /// The microphone's device id; empty for the system default.
  static const voiceMic = Setting<String>('voice.mic', '');

  /// Everyone's voice, in percent.
  static const voiceVolume = Setting<int>('voice.volume', 100, choices: [25, 50, 75, 100, 125, 150, 200]);

  /// How much to lower the movie while others talk, in percent (0 = never).
  static const duckMovie = Setting<int>('voice.duck', 40, choices: [0, 25, 40, 60, 80]);
  static const joinMuted = Setting<bool>('voice.join_muted', true);

  /// Per-person voice volumes as JSON (`{"<user id>": 1.4}`).
  static const voicePeople = Setting<String>('voice.people', '');
}

/// The app's settings, loaded once and saved on every change.
class AppSettings extends ChangeNotifier {
  AppSettings(this._store);

  final SettingsStore _store;
  Map<String, Object> _values = {};

  Future<void> load() async {
    _values = await _store.load();
    notifyListeners();
  }

  T get<T extends Object>(Setting<T> s) {
    final v = _values[s.key];
    if (v is! T) return s.defaultValue;
    final choices = s.choices;
    if (choices != null && !choices.contains(v)) return s.defaultValue;
    return v;
  }

  Future<void> set<T extends Object>(Setting<T> s, T value) async {
    if (value == s.defaultValue) {
      _values.remove(s.key);
      await _store.write(s.key, null);
    } else {
      _values[s.key] = value;
      await _store.write(s.key, value);
    }
    notifyListeners();
  }

  ThemeChoice get theme => ThemeChoice.values.asNameMap()[get(Settings.theme)] ?? ThemeChoice.dark;
  PosterSize get posterSize => PosterSize.values.asNameMap()[get(Settings.posterSize)] ?? PosterSize.medium;
  SubtitleMode get subtitleMode => SubtitleMode.values.asNameMap()[get(Settings.subtitleMode)] ?? SubtitleMode.auto;
  List<String> get audioLanguages => _codes(get(Settings.audioLanguages));
  List<String> get subtitleLanguages => _codes(get(Settings.subtitleLanguages));

  static List<String> _codes(String text) =>
      text.split(RegExp(r'[,\s]+')).map((c) => c.trim().toLowerCase()).where((c) => c.isNotEmpty).toList();
}
