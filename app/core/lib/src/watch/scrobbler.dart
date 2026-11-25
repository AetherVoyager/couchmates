import '../hub/api.dart';
import '../stremio/models.dart';

/// Turns the player's play and pause changes into scrobbles: `start` when
/// playback starts or resumes, `pause` when it pauses, `stop` at the end or
/// when the player closes. Repeats are dropped, so it can be fed every
/// change the player reports.
class Scrobbler {
  Scrobbler._(this._send, this.kind, this.imdb, this.season, this.episode);

  /// Null when [meta] can't be scrobbled (no IMDb id, or an episode without
  /// a season and number).
  static Scrobbler? forTitle(
    Future<void> Function(ScrobbleRequest) send, {
    required StremioMeta meta,
    StremioVideo? video,
  }) {
    final imdb = meta.id;
    if (!RegExp(r'^tt\d+$').hasMatch(imdb)) return null;
    if (video != null && (video.season == null || video.episode == null)) return null;
    return Scrobbler._(send, video == null ? 'movie' : 'episode', imdb, video?.season, video?.episode);
  }

  final Future<void> Function(ScrobbleRequest) _send;
  final String kind;
  final String imdb;
  final int? season;
  final int? episode;

  String? _last;

  Future<void> _report(String action, double progress) async {
    if (_last == action || _last == 'stop') return;
    _last = action;
    await _send(
      ScrobbleRequest(
        action: action,
        kind: kind,
        imdb: imdb,
        season: season,
        episode: episode,
        progress: (progress * 100).clamp(0, 100).toDouble(),
      ),
    );
  }

  /// [fraction] watched, 0–1.
  Future<void> playing(bool isPlaying, double fraction) => _report(isPlaying ? 'start' : 'pause', fraction);

  Future<void> stopped(double fraction) => _report('stop', fraction);

  /// What marking [meta] watched or not watched in the app tells the
  /// trackers: one [video], a whole [season] of a show, or (neither) the
  /// whole movie or show. Null when it can't be sent (no IMDb id, or an
  /// episode without a season and number).
  static ScrobbleRequest? mark(StremioMeta meta, {StremioVideo? video, int? season, required bool watched}) {
    final imdb = meta.id;
    if (!RegExp(r'^tt\d+$').hasMatch(imdb)) return null;
    if (video != null && (video.season == null || video.episode == null)) return null;
    final kind = video != null ? 'episode' : (meta.isSeries ? 'show' : 'movie');
    return ScrobbleRequest(
      action: watched ? 'watched' : 'unwatched',
      kind: kind,
      imdb: imdb,
      season: video?.season ?? (kind == 'show' ? season : null),
      episode: video?.episode,
      progress: watched ? 100 : 0,
    );
  }
}
