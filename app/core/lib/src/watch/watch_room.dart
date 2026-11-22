import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;

import '../stremio/models.dart';
import '../stremio/stremio_client.dart';

/// Something the player can open: a stream of a movie, or of one episode.
class Playable {
  const Playable({required this.meta, required this.stream, this.video, this.audioTrack, this.subtitleTrack});

  final StremioMeta meta;

  /// The audio track picked on the details page (a [MediaTrack.index]), or
  /// null to choose by the preferred languages.
  final int? audioTrack;

  /// The subtitle track picked on the details page: a [MediaTrack.index], 0
  /// for none, or null to choose by the settings.
  final int? subtitleTrack;

  /// The episode, for series.
  final StremioVideo? video;
  final StremioStream stream;

  String get url => stream.url;
  Map<String, String> get headers => stream.headers;

  /// The id the catalog serves streams under: the episode id for series.
  String get streamId => video?.id ?? meta.id;

  String get title {
    final v = video;
    if (v == null) return meta.name;
    final number = v.season != null && v.episode != null ? 'S${v.season} E${v.episode} · ' : '';
    return '${meta.name} · $number${v.title}';
  }
}

/// Reverse-DNS key for Couchmates' own fields in a room's media descriptor.
const _ext = 'app.couchmates';

/// The descriptor for [p], so others in the room can find their own copy.
/// [durationMs] is the player's duration once the file is open.
owp.Media mediaFor(Playable p, int durationMs) {
  final imdb = p.meta.id.startsWith('tt') ? {'imdb': p.meta.id} : const <String, String>{};
  final ext = {
    _ext: {'type': p.meta.type, 'id': p.meta.id, 'stream': p.streamId},
  };
  final file = owp.MediaFile(sizeBytes: p.stream.sizeBytes, name: p.stream.filename);
  final v = p.video;
  if (v == null || v.season == null || v.episode == null) {
    return owp.Media(
      kind: owp.MediaKind.movie,
      title: p.meta.name,
      year: p.meta.year,
      ids: imdb,
      durationMs: durationMs,
      file: file,
      ext: ext,
    );
  }
  return owp.Media(
    kind: owp.MediaKind.episode,
    title: v.title.isEmpty ? 'Episode ${v.episode}' : v.title,
    series: owp.Series(title: p.meta.name, year: p.meta.year, ids: imdb),
    season: v.season,
    episode: v.episode,
    durationMs: durationMs,
    file: file,
    ext: ext,
  );
}

/// Learns a stream's duration by opening it; the app supplies one over its
/// player. Null leaves streams of unknown length unmatchable.
typedef StreamProbe = Future<int?> Function(Playable playable, owp.Cancellation cancel);

/// Finds the user's own copy of the room's title in their catalog.
///
/// Everyone uses the same Telegram-Stremio server, so a stream of the same
/// size as the host's is the same file and gets the host's duration without
/// opening it. Other streams are probed.
class StremioResolver implements owp.Resolver<Playable> {
  StremioResolver(this.catalog, {this.probe});

  final StremioClient catalog;
  final StreamProbe? probe;

  /// The catalog type and ids to look up for [media], or null if it can't
  /// be found in a Stremio catalog.
  static ({String type, String metaId, String streamId})? lookupFor(owp.Media media) {
    final own = media.ext?[_ext];
    if (own is Map && own['type'] is String && own['id'] is String && own['stream'] is String) {
      return (type: own['type'] as String, metaId: own['id'] as String, streamId: own['stream'] as String);
    }
    // From another app: fall back on IMDb ids.
    if (media.kind == owp.MediaKind.movie) {
      final id = media.ids['imdb'];
      return id == null ? null : (type: 'movie', metaId: id, streamId: id);
    }
    final id = media.series?.ids['imdb'];
    if (media.kind == owp.MediaKind.episode && id != null && media.season != null && media.episode != null) {
      return (type: 'series', metaId: id, streamId: '$id:${media.season}:${media.episode}');
    }
    return null;
  }

  @override
  Future<List<owp.Candidate<Playable>>> resolve(owp.Media media, owp.Cancellation cancel) async {
    final lookup = lookupFor(media);
    if (lookup == null) return const [];
    final results = await Future.wait([
      catalog.meta(lookup.type, lookup.metaId),
      catalog.streams(lookup.type, lookup.streamId),
    ]);
    final meta = results[0] as StremioMeta?;
    final streams = (results[1] as StremioStreams).streams;
    if (meta == null || streams.isEmpty) return const [];
    final video = meta.videos.where((v) => v.id == lookup.streamId).firstOrNull;
    final hostSize = media.file?.sizeBytes;
    return [
      for (final (i, s) in streams.indexed)
        _candidate(i, Playable(meta: meta, video: video, stream: s), media, hostSize),
    ];
  }

  owp.Candidate<Playable> _candidate(int index, Playable p, owp.Media media, int? hostSize) {
    final sameFile = hostSize != null && p.stream.sizeBytes == hostSize;
    final probe = this.probe;
    return owp.Candidate(
      id: '$index:${p.stream.url}',
      ref: p,
      name: p.stream.filename ?? p.stream.label,
      sizeBytes: p.stream.sizeBytes,
      durationMs: sameFile ? media.durationMs : null,
      probe: sameFile || probe == null ? null : (cancel) => probe(p, cancel),
    );
  }
}

/// One watch party: create or join a room, share what's playing, and let
/// the room drive the player.
///
/// The app opens [choice] whenever it changes and then calls [attach] with
/// its player; the room keeps that player in sync from then on.
class WatchRoom extends ChangeNotifier {
  WatchRoom({
    required StremioClient catalog,
    required String name,
    owp.Relays? relays,
    StreamProbe? probe,
    String client = 'Couchmates/0.1',
  }) : _party = owp.WatchParty<Playable>(
         relays: relays ?? owp.Relays.public(),
         client: client,
         name: _displayName(name),
         resolver: StremioResolver(catalog, probe: probe),
       ) {
    _states = _party.states.listen((_) => notifyListeners());
  }

  final owp.WatchParty<Playable> _party;
  late final StreamSubscription<void> _states;
  bool _closed = false;

  owp.PartyState<Playable> get state => _party.state;
  Stream<owp.PartyEvent> get events => _party.events;

  bool get inRoom => switch (state.connection) {
    owp.Connection.connecting || owp.Connection.connected || owp.Connection.reconnecting => true,
    _ => false,
  };

  /// The room code as people type it, such as `K7M-Q2X`.
  String? get code => state.room == null ? null : owp.formatCode(state.room!.code);

  /// The raw room code, also the voice room name.
  String? get rawCode => state.room?.code;

  List<owp.Participant> get people => state.room?.participants ?? const [];
  bool get isHost => state.isHost;
  bool get canControl => state.canControl;

  /// The copy of the room's title to open now, if any.
  Playable? get choice => state.choice?.ref;

  /// Creates a room and returns its code. Throws [owp.PartyException].
  Future<String> create() async => owp.formatCode(await _party.create());

  /// Joins by a code as typed. Throws [owp.PartyException].
  Future<void> join(String code) => _party.join(code);

  void leave() => _party.leave();

  /// As host: shares what's playing, [durationMs] long, at [positionMs].
  void share(Playable p, {required int durationMs, int positionMs = 0}) {
    final media = mediaFor(p, durationMs);
    final problem = owp.checkMedia(media);
    if (problem != null) throw ArgumentError(problem);
    _party.setMedia(media, p, positionMs: positionMs);
  }

  void attach(owp.PlayerAdapter player, Playable p) => _party.attachPlayer(player, p);
  Future<void> detach([owp.PlayerAdapter? player]) => _party.detachPlayer(player);
  void playerChanged() => _party.playerChanged();

  void play() => _party.play();
  void pause() => _party.pause();
  void seek(int positionMs) => _party.seek(positionMs);

  void acceptMismatch() => _party.acceptMismatch();
  void declineMismatch() => _party.declineMismatch();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _states.cancel();
    await _party.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

/// The SDK wants 1–32 characters.
String _displayName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Couchmate';
  return trimmed.length > 32 ? trimmed.substring(0, 32) : trimmed;
}
