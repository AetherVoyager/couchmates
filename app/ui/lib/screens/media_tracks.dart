import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../theme.dart';
import '../utils/track_label_builder.dart';

/// The version and tracks picked on a details page for its Play button.
class MediaChoice {
  const MediaChoice({this.stream, this.audio, this.subtitle});

  final StremioStream? stream;

  /// [MediaTrack.index] values picked by hand; null leaves it to the settings.
  final int? audio;

  /// As [audio], with 0 for no subtitles.
  final int? subtitle;
}

/// Track lists by stream URL, so going back to a title doesn't read it again.
final _probes = <String, Future<MediaTracks?>>{};

/// Track lists read before, kept on disk: a file's tracks don't change, so a
/// title opened once shows them at once from then on, even after a restart.
final _disk = _TrackCache();

/// A file's tracks: from this computer when read before, else from the Hub
/// when anyone on it read the file, else read from the file (and shared on
/// the Hub for the next person).
Future<MediaTracks?> tracksOf(StremioStream s, {HubClient? hub}) {
  final cached = _probes[s.url];
  if (cached != null) return cached;
  final key = fileKey(s);
  final f = _disk.get(s.url).then((saved) async {
    if (saved != null) return saved;
    if (hub != null && key != null) {
      try {
        final shared = MediaTracksShared.fromShared(await hub.fileTracks(key));
        if (shared != null) {
          _disk.put(s.url, shared);
          return shared;
        }
      } catch (_) {
        // An older Hub or no connection: read the file instead.
      }
    }
    final read = await probeStream(s);
    if (read != null) {
      _disk.put(s.url, read);
      if (hub != null && key != null && !read.isEmpty) {
        unawaited(hub.saveFileTracks(key, read.toShared()).catchError((_) {}));
      }
    }
    return read;
  });
  _probes[s.url] = f;
  // A failure may be passing (a slow server): try again next time.
  unawaited(f.then((t) => t == null ? _probes.remove(s.url) : null));
  return f;
}

/// Streams by title (or episode) id, for a few minutes: the details page and
/// an early read from hovering its poster share one request.
final _streams = <String, (DateTime, Future<StremioStreams>)>{};

Future<StremioStreams> streamsOf(StremioClient catalog, String type, String id) {
  final key = '$type/$id';
  final hit = _streams[key];
  if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 10)) return hit.$2;
  final f = catalog.streams(type, id);
  _streams[key] = (DateTime.now(), f);
  unawaited(f.then((_) {}, onError: (_) => _streams.remove(key)));
  return f;
}

/// Starts reading a movie's streams and first file's tracks before its
/// details page opens (on hovering its poster), so they're ready when it does.
void prefetchTracks(BuildContext context, StremioMeta meta) {
  if (meta.isSeries) return;
  final session = context.read<HubSession>();
  final catalog = session.catalog;
  if (catalog == null) return;
  unawaited(
    streamsOf(catalog, meta.type, meta.id).then((s) {
      final first = s.streams.firstOrNull;
      if (first != null) unawaited(tracksOf(first, hub: session.hub));
    }, onError: (_) {}),
  );
}

class _TrackCache {
  static const _max = 1000;

  Future<Map<String, Object?>>? _data;
  File? _file;
  Timer? _save;

  Future<Map<String, Object?>> _load() => _data ??= () async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = _file = File('${dir.path}${Platform.pathSeparator}media_tracks.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, Object?>) return j;
      }
    } catch (e) {
      debugPrint('track cache: $e');
    }
    return <String, Object?>{};
  }();

  Future<MediaTracks?> get(String url) async => MediaTracks.fromJson((await _load())[url]);

  void put(String url, MediaTracks t) {
    unawaited(
      _load().then((m) {
        m.remove(url);
        m[url] = t.toJson();
        // Oldest first: drop from the front.
        while (m.length > _max) {
          m.remove(m.keys.first);
        }
        _save?.cancel();
        _save = Timer(const Duration(seconds: 2), () => unawaited(_write(m)));
      }),
    );
  }

  Future<void> _write(Map<String, Object?> m) async {
    final f = _file;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(m), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('track cache: $e');
    }
  }
}

/// "Malayalam", or the track's name or number when it has no language.
String trackName(MediaTrack t) =>
    resolveTrackLanguageDisplay(language: t.language) ??
    t.name ??
    (t.kind == MediaTrackKind.audio ? 'Track ${t.index}' : 'Subtitles ${t.index}');

/// "E-AC3 5.1 · Forced", plus the track's own name when it adds something.
String? trackDetail(MediaTrack t) {
  final lang = resolveTrackLanguageDisplay(language: t.language);
  final name = t.name;
  final parts = [
    if (name != null && lang != null && name.toLowerCase() != lang.toLowerCase()) name,
    if (t.codec != null && !(name ?? '').toUpperCase().contains(t.codec!.toUpperCase())) t.codec!,
    if (t.kind == MediaTrackKind.audio && !(name ?? '').contains(channelLabel(t.channels) ?? '\u0000'))
      ?channelLabel(t.channels),
    if (t.isForced) 'Forced',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _resolution(MediaTrack v) {
  final h = v.height, w = v.width;
  if (h == null || w == null) return '';
  if (w >= 3800 || h >= 2100) return '4K';
  if (w >= 1900 || h >= 1060) return '1080p';
  if (w >= 1260 || h >= 700) return '720p';
  return '${h}p';
}

/// The version, video, audio and subtitles of what Play will play, read from
/// the file before playing, with pickers when there's a choice. Like Plezy's
/// details page.
class MediaPickers extends StatefulWidget {
  const MediaPickers({super.key, required this.meta, this.video, required this.onChanged});

  final StremioMeta meta;

  /// The episode Play plays, for shows.
  final StremioVideo? video;
  final ValueChanged<MediaChoice> onChanged;

  @override
  State<MediaPickers> createState() => _MediaPickersState();
}

class _MediaPickersState extends State<MediaPickers> {
  late final Future<StremioStreams> _streamsF;
  List<StremioStream> _list = const [];
  int _version = 0;
  Future<MediaTracks?>? _tracks;
  int? _audio;
  int? _subtitle;

  @override
  void initState() {
    super.initState();
    final catalog = context.read<HubSession>().catalog!;
    _streamsF = streamsOf(catalog, widget.meta.type, widget.video?.id ?? widget.meta.id);
    unawaited(
      _streamsF.then((s) {
        if (!mounted || s.streams.isEmpty) return;
        setState(() {
          _list = s.streams;
          _tracks = tracksOf(_list.first, hub: context.read<HubSession>().hub);
        });
        _emit();
      }, onError: (_) {}),
    );
  }

  void _emit() =>
      widget.onChanged(MediaChoice(stream: _list.isEmpty ? null : _list[_version], audio: _audio, subtitle: _subtitle));

  void _pickVersion(int i) {
    setState(() {
      _version = i;
      _audio = null;
      _subtitle = null;
      _tracks = tracksOf(_list[i], hub: context.read<HubSession>().hub);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return FutureBuilder<StremioStreams>(
      future: _streamsF,
      builder: (context, snap) {
        if (_list.isEmpty) return const SizedBox.shrink();
        final stream = _list[_version];
        final details = streamDetails(stream);
        String? detail(StreamDetailKind k) => details.where((d) => d.kind == k).map((d) => d.text).firstOrNull;
        return FutureBuilder<MediaTracks?>(
          future: _tracks,
          builder: (context, t) {
            final reading = t.connectionState != ConnectionState.done;
            final tracks = t.data;
            final expected = tracks == null ? null : expectedTracks(tracks, settings);
            final audio = _audio ?? expected?.audio;
            final subtitle = _subtitle ?? expected?.subtitle;
            final video = tracks?.video.firstOrNull;

            final pills = <Widget>[
              if (_list.length > 1)
                _Pill<int>(
                  icon: Icons.video_file_outlined,
                  label: 'Version',
                  value: [stream.label, ?detail(StreamDetailKind.size)].join(' · '),
                  selected: _version,
                  options: [
                    for (final (i, s) in _list.indexed)
                      (
                        i,
                        s.label,
                        [
                          ?streamDetails(s).where((d) => d.kind == StreamDetailKind.video).firstOrNull?.text,
                          ?streamDetails(s).where((d) => d.kind == StreamDetailKind.size).firstOrNull?.text,
                        ].join(' · '),
                      ),
                  ],
                  onPicked: _pickVersion,
                ),
              if (video != null)
                _Pill<int>(
                  icon: Icons.videocam_outlined,
                  label: 'Video',
                  value: [_resolution(video), ?video.codec].where((s) => s.isNotEmpty).join(' · '),
                )
              else if (!reading && detail(StreamDetailKind.video) != null)
                _Pill<int>(icon: Icons.videocam_outlined, label: 'Video', value: detail(StreamDetailKind.video)!),
              if (reading)
                const _Pill<int>(icon: Icons.graphic_eq_rounded, label: 'Audio & subtitles', value: 'Reading the file…')
              else if (tracks == null) ...[
                _Pill<int>(
                  icon: Icons.graphic_eq_rounded,
                  label: 'Audio',
                  value:
                      [?detail(StreamDetailKind.language), ?detail(StreamDetailKind.audio)].join(' · ').ifEmpty ??
                      'Pick in the player',
                  tooltip: "This file's tracks couldn't be read ahead. All of them are in the player's audio menu.",
                ),
                const _Pill<int>(
                  icon: Icons.subtitles_outlined,
                  label: 'Subtitles',
                  value: 'Pick in the player',
                  tooltip: "This file's tracks couldn't be read ahead. All of them are in the player's subtitles menu.",
                ),
              ] else ...[
                if (tracks.audio.isNotEmpty)
                  _Pill<int>(
                    icon: Icons.graphic_eq_rounded,
                    label: tracks.audio.length > 1 ? 'Audio · ${tracks.audio.length} tracks' : 'Audio',
                    value: _describe(tracks.audio.where((a) => a.index == audio).firstOrNull ?? tracks.audio.first),
                    selected: audio,
                    options: [for (final a in tracks.audio) (a.index, trackName(a), trackDetail(a))],
                    onPicked: (i) {
                      setState(() => _audio = i);
                      _emit();
                    },
                  ),
                _Pill<int>(
                  icon: Icons.subtitles_outlined,
                  label: tracks.subtitles.length > 1 ? 'Subtitles · ${tracks.subtitles.length}' : 'Subtitles',
                  value: tracks.subtitles.isEmpty
                      ? 'None in this file'
                      : subtitle == null || subtitle == 0
                      ? 'Off'
                      : _describe(tracks.subtitles.firstWhere((s) => s.index == subtitle)),
                  selected: tracks.subtitles.isEmpty ? null : subtitle ?? 0,
                  options: tracks.subtitles.isEmpty
                      ? const []
                      : [(0, 'Off', null), for (final s in tracks.subtitles) (s.index, trackName(s), trackDetail(s))],
                  onPicked: (i) {
                    setState(() => _subtitle = i);
                    _emit();
                  },
                ),
              ],
            ];
            final file = detail(StreamDetailKind.file);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 10, runSpacing: 10, children: pills),
                if (file != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    [file, if (_list.length == 1) ?detail(StreamDetailKind.size)].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Cinema.faint),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  String _describe(MediaTrack t) {
    final d = trackDetail(t);
    return d == null ? trackName(t) : '${trackName(t)} · $d';
  }
}

extension on String {
  String? get ifEmpty => isEmpty ? null : this;
}

/// A small labelled box with a value; a menu of [options] when there's more
/// than one.
class _Pill<T> extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.label,
    required this.value,
    this.options = const [],
    this.selected,
    this.onPicked,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final String value;

  /// (value, title, detail).
  final List<(T, String, String?)> options;
  final T? selected;
  final ValueChanged<T>? onPicked;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final menu = options.length > 1 && onPicked != null;
    final box = Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        border: Border.all(color: menu ? Colors.white38 : Colors.white12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: Cinema.muted),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(color: Cinema.faint, letterSpacing: 1),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          if (menu) ...[const SizedBox(width: 6), const Icon(Icons.arrow_drop_down, color: Colors.white70)],
        ],
      ),
    );
    if (!menu) return tooltip == null ? box : Tooltip(message: tooltip!, child: box);
    return PopupMenuButton<T>(
      tooltip: tooltip ?? 'Choose ${label.split(' ·').first.toLowerCase()}',
      initialValue: selected,
      onSelected: onPicked,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final (v, title, detail) in options)
          CheckedPopupMenuItem<T>(
            value: v,
            checked: v == selected,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title),
                if (detail != null && detail.isNotEmpty)
                  Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: Cinema.muted)),
              ],
            ),
          ),
      ],
      child: box,
    );
  }
}
