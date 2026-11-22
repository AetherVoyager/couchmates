import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../settings/app_settings.dart';
import '../stremio/models.dart';

/// Where the user stopped in one movie or episode.
class WatchProgress {
  const WatchProgress({
    required this.metaId,
    required this.type,
    required this.name,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.videoId,
    this.videoTitle,
    this.poster,
    this.background,
  });

  final String metaId;
  final String type;
  final String name;
  final String? videoId;
  final String? videoTitle;
  final String? poster;
  final String? background;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  /// The movie id, or the episode's id.
  String get key => videoId ?? metaId;
  double get fraction => durationMs <= 0 ? 0 : positionMs / durationMs;

  /// Watched to the end (credits count as the end).
  bool get finished => fraction >= 0.92;

  /// Worth resuming: past the opening minute and not finished.
  bool get resumable => positionMs >= 60000 && !finished;

  /// The catalog entry to open for this.
  StremioMeta get meta => StremioMeta(id: metaId, type: type, name: name, poster: poster, background: background);

  Map<String, Object?> toJson() => {
    'meta': metaId,
    'type': type,
    'name': name,
    'video': videoId,
    'video_title': videoTitle,
    'poster': poster,
    'background': background,
    'pos': positionMs,
    'dur': durationMs,
    'at': updatedAt.millisecondsSinceEpoch,
  };

  static WatchProgress? fromJson(Object? j) {
    if (j is! Map) return null;
    final meta = j['meta'], type = j['type'], pos = j['pos'], dur = j['dur'], at = j['at'];
    if (meta is! String || type is! String || pos is! int || dur is! int || at is! int) return null;
    return WatchProgress(
      metaId: meta,
      type: type,
      name: j['name'] as String? ?? '',
      videoId: j['video'] as String?,
      videoTitle: j['video_title'] as String?,
      poster: j['poster'] as String?,
      background: j['background'] as String?,
      positionMs: pos,
      durationMs: dur,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// Watch progress on this device, newest first, kept in the settings store
/// as one JSON value. The most recent [maxEntries] are kept.
class ProgressStore extends ChangeNotifier {
  ProgressStore(this._store);

  static const _key = 'progress.entries';
  static const maxEntries = 200;

  final SettingsStore _store;
  final Map<String, WatchProgress> _entries = {};

  Future<void> load() async {
    final raw = (await _store.load())[_key];
    _entries.clear();
    if (raw is String) {
      try {
        for (final e in (jsonDecode(raw) as List)) {
          final p = WatchProgress.fromJson(e);
          if (p != null) _entries[p.key] = p;
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  WatchProgress? of(String key) => _entries[key];

  /// The latest entry for a title (any episode of a show).
  WatchProgress? latestFor(String metaId) {
    WatchProgress? best;
    for (final p in _entries.values) {
      if (p.metaId == metaId && (best == null || p.updatedAt.isAfter(best.updatedAt))) best = p;
    }
    return best;
  }

  /// Unfinished titles, newest first, one per show.
  List<WatchProgress> get continueWatching {
    final seen = <String>{};
    final list = _entries.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [
      for (final p in list)
        if (seen.add(p.metaId) && p.resumable) p,
    ];
  }

  Future<void> save(WatchProgress p) async {
    _entries[p.key] = p;
    if (_entries.length > maxEntries) {
      final oldest = _entries.values.reduce((a, b) => a.updatedAt.isBefore(b.updatedAt) ? a : b);
      _entries.remove(oldest.key);
    }
    await _persist();
  }

  /// Marks a movie (no [video]) or an episode watched, or not watched.
  Future<void> setWatched(StremioMeta meta, {StremioVideo? video, required bool watched}) async {
    final key = video?.id ?? meta.id;
    if (!watched) return forget(key);
    await save(
      WatchProgress(
        metaId: meta.id,
        type: meta.type,
        name: meta.name,
        videoId: video?.id,
        videoTitle: video?.title,
        poster: meta.poster,
        background: meta.background,
        positionMs: 1,
        durationMs: 1,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Marks every episode of [videos] at once (one save).
  Future<void> setManyWatched(StremioMeta meta, List<StremioVideo> videos, {required bool watched}) async {
    // Stamped in order, so the last episode counts as the last watched.
    final start = DateTime.now();
    for (final (i, v) in videos.indexed) {
      final now = start.add(Duration(milliseconds: i));
      if (watched) {
        _entries[v.id] = WatchProgress(
          metaId: meta.id,
          type: meta.type,
          name: meta.name,
          videoId: v.id,
          videoTitle: v.title,
          poster: meta.poster,
          background: meta.background,
          positionMs: 1,
          durationMs: 1,
          updatedAt: now,
        );
      } else {
        _entries.remove(v.id);
      }
    }
    await _persist();
  }

  bool isWatched(String key) => _entries[key]?.finished ?? false;

  Future<void> forget(String key) async {
    if (_entries.remove(key) != null) await _persist();
  }

  Future<void> _persist() async {
    await _store.write(_key, jsonEncode([for (final p in _entries.values) p.toJson()]));
    notifyListeners();
  }
}
