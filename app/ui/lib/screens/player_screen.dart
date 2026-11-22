import 'dart:async';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../mpv/mpv.dart' as mpv;
import '../utils/track_label_builder.dart';
import '../watch_together/mpv_adapter.dart';
import '../watch_together/friends.dart';
import '../watch_together/watch_together.dart';
import '../watch_together/watch_together_sheet.dart';
import '../widgets/voice_button.dart';
import 'media_info_panel.dart';

const _window = MethodChannel('plezy/window');

/// Stremio's OpenSubtitles addon, for subtitles the file doesn't have when
/// the catalog isn't an [AddonSet] (which has its own subtitle add-ons).
final _openSubtitles = StremioClient(baseUrl: openSubtitlesAddon);

/// Plays one [Playable] with mpv. In a watch party it shares the title (as
/// host) or follows the room's choice, and play, pause and seek go through
/// the room so everyone stays together.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.playable});

  final Playable playable;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final WatchTogether _watch;
  late final FriendsLink _friends;
  late final mpv.Player _player;
  late final MpvPartyAdapter _adapter;
  late final AppSettings _settings;
  late final ProgressStore _progress;
  final _subs = <StreamSubscription<Object?>>[];
  final _focus = FocusNode();
  Timer? _saveTimer;
  bool _tracksChosen = false;
  bool _resumeChecked = false;
  bool _endHandled = false;
  double _volume = 100;
  Scrobbler? _scrobbler;
  double _volumeBeforeMute = 100;

  /// The movie is lowered while others talk in voice chat.
  bool _ducked = false;
  Timer? _unduck;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = true;

  /// Until the first frame, the native video layer under the window shows
  /// nothing, so the screen stays black instead of see-through.
  bool _started = false;
  mpv.Tracks _tracks = const mpv.Tracks();
  mpv.TrackSelection _selection = const mpv.TrackSelection();
  String? _error;

  /// Subtitles OpenSubtitles has for this title (null until they arrive),
  /// the ones loaded into the player by URL, and the language to load one in
  /// at start when the file has none the settings want.
  List<OnlineSubtitle>? _online;
  final _onlineAdded = <String>{};
  String? _autoOnline;
  bool _autoOnlineDone = false;

  /// The room the player is attached to, if any.
  WatchRoom? _attachedTo;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _fullscreen = false;
  double? _dragging;
  bool _showInfo = false;

  Playable get _p => widget.playable;

  @override
  void initState() {
    super.initState();
    _watch = context.read<WatchTogether>();
    _watch.playing = _p;
    _friends = context.read<FriendsLink>()..playerState(_p, paused: true);
    _watch.addListener(_syncRoom);
    _watch.voice.addListener(_duck);
    _settings = context.read<AppSettings>();
    _progress = context.read<ProgressStore>();
    _volume = _settings.get(Settings.defaultVolume).toDouble();
    _player = mpv.Player(hardwareDecoding: _settings.get(Settings.hardwareDecoding));
    final session = context.read<HubSession>();
    _scrobbler = Scrobbler.forTitle(session.scrobble, meta: _p.meta, video: _p.video);
    _adapter = MpvPartyAdapter(_player);
    final s = _player.streams;
    _subs.addAll([
      s.position.listen((v) => setState(() => _position = v)),
      s.duration.listen((v) {
        setState(() => _duration = v);
        _maybeResume();
        _syncRoom();
      }),
      s.playing.listen((v) {
        setState(() => _playing = v);
        _friends.playerState(_p, paused: !v);
        _attachedTo?.playerChanged();
        if (_duration > Duration.zero) unawaited(_scrobbler?.playing(v, _fraction));
      }),
      s.buffering.listen((v) {
        setState(() => _buffering = v);
        _attachedTo?.playerChanged();
      }),
      s.playheadJump.listen((_) => _attachedTo?.playerChanged()),
      s.playbackRestart.listen((_) {
        if (!_started) setState(() => _started = true);
      }),
      s.tracks.listen((v) {
        setState(() => _tracks = v);
        _chooseTracks();
      }),
      s.track.listen((v) => setState(() => _selection = v)),
      s.error.listen((e) => setState(() => _error = e.message)),
      s.completed.listen((done) {
        if (done) unawaited(_onEnded());
      }),
      _watch.notices.stream.listen(_toast),
    ]);
    _open();
    if (_settings.get(Settings.onlineSubtitles)) unawaited(_loadOnlineSubtitles());
    _scheduleHide();
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_playing) unawaited(_saveProgress());
    });
  }

  Future<void> _open() async {
    try {
      // In a party the room decides when to start, so open paused.
      final partyChoice = _watch.room?.inRoom == true && !(_watch.room?.isHost ?? true);
      await _player.open(mpv.Media(_p.url, headers: _p.headers.isEmpty ? null : _p.headers), play: !partyChoice);
      await _player.setVolume(_volume);
      final scale = _settings.get(Settings.subtitleSize) / 100;
      if (scale != 1) await _player.setProperty('sub-scale', scale.toStringAsFixed(2));
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't open this stream.");
    }
  }

  Future<void> _loadOnlineSubtitles() async {
    final catalog = context.read<HubSession>().catalog;
    final subs = await fetchOnlineSubtitles(catalog is AddonSet ? catalog : _openSubtitles, _p);
    if (!mounted) return;
    setState(() => _online = subs);
    _maybeAutoOnline();
  }

  /// Loads the best online subtitle in [_autoOnline] once both the file's
  /// tracks and the online list are known.
  void _maybeAutoOnline() {
    final lang = _autoOnline, online = _online;
    if (_autoOnlineDone || lang == null || online == null) return;
    _autoOnlineDone = true;
    final best = online.where((s) => normalizeLanguage(s.language) == lang).firstOrNull;
    if (best != null) unawaited(_addOnline(best));
  }

  /// Loads [sub] into mpv as an external track and shows it.
  Future<void> _addOnline(OnlineSubtitle sub) async {
    if (!_onlineAdded.add(sub.url)) return;
    setState(() {});
    try {
      await _player.command(['sub-add', sub.url, 'select', 'Online', sub.language]);
    } catch (_) {
      _onlineAdded.remove(sub.url);
      if (mounted) setState(() {});
      _toast("Couldn't load that subtitle.");
    }
  }

  /// Attaches to the room once the file is open: shares it as host, or
  /// follows when it's the room's choice.
  void _syncRoom() {
    if (!mounted) return;
    final room = _watch.room;
    if (_attachedTo != null && (room == null || !identical(room, _attachedTo) || !room.inRoom)) {
      _attachedTo = null;
      setState(() {});
    }
    if (room == null || !room.inRoom || _attachedTo != null || _duration <= Duration.zero) return;
    if (room.isHost) {
      final shared = room.state.choice?.ref.url == _p.url;
      if (!shared) room.share(_p, durationMs: _duration.inMilliseconds, positionMs: _position.inMilliseconds);
      room.attach(_adapter, _p);
      _attachedTo = room;
    } else if (room.choice?.url == _p.url) {
      room.attach(_adapter, _p);
      _attachedTo = room;
    }
    setState(() {});
  }

  /// Picks audio and subtitles by the preferred languages, once, when the
  /// file's tracks are first known.
  void _chooseTracks() {
    if (_tracksChosen || (_tracks.audio.isEmpty && _tracks.subtitle.isEmpty)) return;
    _tracksChosen = true;
    // A choice made on the details page wins over the preferred languages.
    final pickedAudio = _p.audioTrack, pickedSub = _p.subtitleTrack;
    if (pickedAudio != null && pickedAudio <= _tracks.audio.length) {
      unawaited(_player.selectAudioTrack(_tracks.audio[pickedAudio - 1]));
    }
    if (pickedSub == 0) {
      unawaited(_player.selectSubtitleTrack(mpv.SubtitleTrack.off));
    } else if (pickedSub != null && pickedSub <= _tracks.subtitle.length) {
      unawaited(_player.selectSubtitleTrack(_tracks.subtitle[pickedSub - 1]));
    }
    if (pickedAudio != null || pickedSub != null) return;
    final audioId = chooseAudio([
      for (final t in _tracks.audio) TrackInfo(id: t.id, language: t.language, title: t.title),
    ], _settings.audioLanguages);
    final audio = _tracks.audio.where((t) => t.id == audioId).firstOrNull;
    if (audio != null) unawaited(_player.selectAudioTrack(audio));
    final audioLanguage = (audio ?? _selection.audio ?? _tracks.audio.firstOrNull)?.language;
    final subId = chooseSubtitle(
      [for (final t in _tracks.subtitle) TrackInfo(id: t.id, language: t.language, title: t.title, forced: t.isForced)],
      mode: _settings.subtitleMode,
      preferredSubtitles: _settings.subtitleLanguages,
      preferredAudio: _settings.audioLanguages,
      audioLanguage: audioLanguage,
    );
    if (subId == 'no') {
      unawaited(_player.selectSubtitleTrack(mpv.SubtitleTrack.off));
    } else if (subId != null) {
      final sub = _tracks.subtitle.where((t) => t.id == subId).firstOrNull;
      if (sub != null) unawaited(_player.selectSubtitleTrack(sub));
    }
    if (_settings.get(Settings.onlineSubtitles)) {
      _autoOnline = autoOnlineLanguage(
        [
          for (final t in _tracks.subtitle)
            TrackInfo(id: t.id, language: t.language, title: t.title, forced: t.isForced),
        ],
        _settings,
        audioLanguage: audioLanguage,
      );
      _maybeAutoOnline();
    }
  }

  /// Jumps to where the user stopped last time, unless the room decides.
  void _maybeResume() {
    if (_resumeChecked || _duration <= Duration.zero) return;
    _resumeChecked = true;
    final room = _watch.room;
    if (room != null && room.inRoom && !room.isHost) return;
    if (!_settings.get(Settings.resume)) return;
    final saved = _progress.of(_p.streamId);
    if (saved == null || !saved.resumable) return;
    final at = Duration(milliseconds: saved.positionMs);
    unawaited(_player.seek(at));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Resumed at ${_fmt(at)}'),
          action: SnackBarAction(label: 'Start over', onPressed: () => _seekTo(Duration.zero)),
        ),
      );
  }

  Future<void> _saveProgress() async {
    if (_duration <= Duration.zero || _position <= Duration.zero) return;
    await _progress.save(
      WatchProgress(
        metaId: _p.meta.id,
        type: _p.meta.type,
        name: _p.meta.name,
        videoId: _p.video?.id,
        videoTitle: _p.video?.title,
        poster: _p.meta.poster,
        background: _p.meta.background,
        positionMs: _position.inMilliseconds,
        durationMs: _duration.inMilliseconds,
        updatedAt: DateTime.now(),
      ),
    );
  }

  double get _fraction => _duration <= Duration.zero ? 0 : _position.inMilliseconds / _duration.inMilliseconds;

  StremioVideo? get _nextEpisode => _p.video == null ? null : _p.meta.nextAfter(_p.video!.id);

  /// At the end: the next episode when that's on, otherwise back out. A
  /// guest in a party stays; the host's next pick comes through the room.
  Future<void> _onEnded() async {
    if (_endHandled) return;
    _endHandled = true;
    _position = _duration;
    unawaited(_scrobbler?.stopped(1));
    await _saveProgress();
    final room = _attachedTo;
    if (room != null && !room.isHost) return;
    final next = _nextEpisode;
    if (next != null && _settings.get(Settings.autoplayNext)) {
      await _playNext(next);
    } else if (room == null && mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  /// Opens [next] in a new player, preferring a stream like this one.
  Future<void> _playNext(StremioVideo next) async {
    final catalog = context.read<HubSession>().catalog;
    if (catalog == null) return;
    try {
      final result = await catalog.streams(_p.meta.type, next.id);
      final group = _p.stream.bingeGroup;
      final stream =
          result.streams.where((s) => group != null && s.bingeGroup == group).firstOrNull ?? result.streams.firstOrNull;
      if (stream == null) {
        _toast("The next episode isn't available yet.");
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            playable: Playable(meta: _p.meta, video: next, stream: stream),
          ),
        ),
      );
    } catch (_) {
      _toast("Couldn't load the next episode.");
    }
  }

  void _setVolume(double v) {
    _volume = v.clamp(0, 100).toDouble();
    unawaited(_player.setVolume(_playedVolume));
    _toast('Volume ${_volume.round()}%');
  }

  /// The volume sent to the player: lowered while others talk.
  double get _playedVolume {
    final duck = _settings.get(Settings.duckMovie);
    return _ducked && duck > 0 ? _volume * (100 - duck) / 100 : _volume;
  }

  /// Lowers the movie as soon as someone talks; brings it back after a
  /// short quiet, so it doesn't pump between words.
  void _duck() {
    if (!mounted || _settings.get(Settings.duckMovie) == 0) return;
    if (_watch.voice.othersSpeaking) {
      _unduck?.cancel();
      _unduck = null;
      if (!_ducked) {
        _ducked = true;
        unawaited(_player.setVolume(_playedVolume));
      }
    } else if (_ducked && _unduck == null) {
      _unduck = Timer(const Duration(milliseconds: 1200), () {
        _unduck = null;
        if (!mounted || _watch.voice.othersSpeaking) return;
        _ducked = false;
        unawaited(_player.setVolume(_playedVolume));
      });
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    if (!_endHandled) {
      unawaited(_saveProgress());
      unawaited(_scrobbler?.stopped(_fraction));
    }
    _watch.removeListener(_syncRoom);
    _watch.voice.removeListener(_duck);
    _unduck?.cancel();
    if (identical(_watch.playing, _p)) _watch.playing = null;
    _friends.playerClosed(_p);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    final room = _attachedTo;
    unawaited(() async {
      if (room != null) await room.detach(_adapter);
      await _player.dispose();
    }());
    if (_fullscreen) unawaited(_setFullscreen(false));
    _focus.dispose();
    super.dispose();
  }

  // --- Commands: through the room when in a party.

  void _togglePlay() {
    final room = _attachedTo;
    if (room != null) {
      if (!room.canControl) return _toast('Only the host can control playback.');
      _playing ? room.pause() : room.play();
    } else {
      unawaited(_player.playOrPause());
    }
    _bump();
  }

  void _seekTo(Duration to) {
    final clamped = to < Duration.zero ? Duration.zero : (_duration > Duration.zero && to > _duration ? _duration : to);
    final room = _attachedTo;
    if (room != null) {
      if (!room.canControl) return _toast('Only the host can control playback.');
      room.seek(clamped.inMilliseconds);
    } else {
      unawaited(_player.seek(clamped));
    }
    _bump();
  }

  void _seekBy(int seconds) => _seekTo(_position + Duration(seconds: seconds));

  Future<void> _setFullscreen(bool on) async {
    if (!(Platform.isWindows)) {
      await SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    } else {
      try {
        await _window.invokeMethod('setFullScreen', {'isFullScreen': on});
      } on MissingPluginException {
        return;
      }
    }
    if (mounted) setState(() => _fullscreen = on);
  }

  // --- Controls visibility.

  void _bump() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(Duration(seconds: _settings.get(Settings.hideAfter)), () {
      if (mounted && _playing && _dragging == null) setState(() => _controlsVisible = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _togglePlay();
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _seekBy(-_settings.get(Settings.seekBack));
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      _seekBy(_settings.get(Settings.seekForward));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _setVolume(_volume + 5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _setVolume(_volume - 5);
    } else if (key == LogicalKeyboardKey.keyM) {
      if (_volume > 0) {
        _volumeBeforeMute = _volume;
        _setVolume(0);
      } else {
        _setVolume(_volumeBeforeMute);
      }
    } else if (key == LogicalKeyboardKey.keyI) {
      setState(() => _showInfo = !_showInfo);
    } else if (key == LogicalKeyboardKey.keyN) {
      final next = _nextEpisode;
      if (next != null) unawaited(_playNext(next));
    } else if (key == LogicalKeyboardKey.keyF) {
      unawaited(_setFullscreen(!_fullscreen));
    } else if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        unawaited(_setFullscreen(false));
      } else {
        Navigator.of(context).maybePop();
      }
    } else {
      return KeyEventResult.ignored;
    }
    _bump();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final watch = context.watch<WatchTogether>();
    final room = watch.room;
    final mismatch = room?.state.mismatch;
    // The friends bubble shows and hides with the controls.
    final controls = _controlsVisible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _friends.playerControlsShown(controls);
    });
    return Scaffold(
      // Transparent all the way down: on desktop the video is drawn on a
      // native layer under the Flutter surface.
      backgroundColor: Colors.transparent,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
          onHover: (_) => _bump(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controlsVisible ? setState(() => _controlsVisible = false) : _bump(),
            onDoubleTap: _settings.get(Settings.doubleClickFullscreen) ? () => _setFullscreen(!_fullscreen) : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                mpv.Video(player: _player, backgroundColor: Colors.transparent),
                if (!_started || _error != null) const ColoredBox(color: Colors.black),
                if (_buffering && _error == null) const Center(child: CircularProgressIndicator()),
                if (_error != null) Center(child: _Bubble(text: _error!)),
                if (mismatch != null)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: _Bubble(
                        text:
                            "Your copy is ${(mismatch.deltaMs.abs() / 1000).round()} s ${mismatch.deltaMs > 0 ? 'longer' : 'shorter'} than the room's. Play it anyway?",
                        actions: [
                          TextButton(onPressed: room!.declineMismatch, child: const Text('No')),
                          FilledButton(onPressed: room.acceptMismatch, child: const Text('Play')),
                        ],
                      ),
                    ),
                  ),
                if (_showInfo)
                  Positioned(
                    top: 72,
                    right: 16,
                    child: MediaInfoPanel(player: _player, onClose: () => setState(() => _showInfo = false)),
                  ),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(ignoring: !_controlsVisible, child: _controls(context, watch)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, WatchTogether watch) {
    final room = watch.room;
    final shade = Colors.black.withValues(alpha: 0.6);
    final position = _dragging != null ? Duration(milliseconds: _dragging!.round()) : _position;
    final max = _duration.inMilliseconds.toDouble();
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [shade, Colors.transparent],
            ),
          ),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
                if (room?.inRoom == true) ...[
                  Chip(
                    avatar: const Icon(Icons.groups_rounded, size: 18),
                    label: Text('${room!.people.length} · ${room.code ?? ''}'),
                  ),
                  const SizedBox(width: 4),
                  const VoiceButton(),
                ],
                IconButton(
                  tooltip: 'Watch together',
                  icon: const Icon(Icons.group_add_outlined, color: Colors.white),
                  onPressed: () => showWatchTogetherSheet(context),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [shade, Colors.transparent],
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Row(
                  children: [
                    Text(_fmt(position), style: const TextStyle(color: Colors.white)),
                    Expanded(
                      child: Slider(
                        value: max <= 0 ? 0 : position.inMilliseconds.clamp(0, max).toDouble(),
                        max: max <= 0 ? 1 : max,
                        onChangeStart: (v) => setState(() => _dragging = v),
                        onChanged: (v) => setState(() => _dragging = v),
                        onChangeEnd: (v) {
                          setState(() => _dragging = null);
                          _seekTo(Duration(milliseconds: v.round()));
                        },
                      ),
                    ),
                    Text(_fmt(_duration), style: const TextStyle(color: Colors.white)),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Back ${_settings.get(Settings.seekBack)} seconds',
                      icon: Icon(_backIcon(_settings.get(Settings.seekBack)), color: Colors.white),
                      onPressed: () => _seekBy(-_settings.get(Settings.seekBack)),
                    ),
                    IconButton(
                      tooltip: _playing ? 'Pause' : 'Play',
                      iconSize: 40,
                      icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                      onPressed: _togglePlay,
                    ),
                    IconButton(
                      tooltip: 'Forward ${_settings.get(Settings.seekForward)} seconds',
                      icon: Icon(_forwardIcon(_settings.get(Settings.seekForward)), color: Colors.white),
                      onPressed: () => _seekBy(_settings.get(Settings.seekForward)),
                    ),
                    if (_nextEpisode != null)
                      IconButton(
                        tooltip: 'Next episode',
                        icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                        onPressed: () => _playNext(_nextEpisode!),
                      ),
                    const Spacer(),
                    _trackMenu(
                      icon: Icons.audiotrack_outlined,
                      tooltip: 'Audio',
                      items: [
                        for (final (i, t) in _tracks.audio.indexed)
                          (
                            label: TrackLabelBuilder.audioLabel(
                              title: t.title,
                              language: t.language,
                              codec: t.codec,
                              channels: t.channels,
                              index: i,
                            ).primary,
                            selected: _selection.audio?.id == t.id,
                            onTap: () => _player.selectAudioTrack(t),
                          ),
                      ],
                    ),
                    _trackMenu(
                      icon: Icons.subtitles_outlined,
                      tooltip: 'Subtitles',
                      items: [
                        (
                          label: 'Off',
                          selected: _selection.subtitle == null || _selection.subtitle?.id == 'no',
                          onTap: () => _player.selectSubtitleTrack(mpv.SubtitleTrack.off),
                        ),
                        for (final (i, t) in _tracks.subtitle.indexed)
                          (
                            label: TrackLabelBuilder.subtitleLabel(
                              title: t.title,
                              language: t.language,
                              codec: t.codec,
                              forced: t.isForced,
                              index: i,
                            ).primary,
                            selected: _selection.subtitle?.id == t.id,
                            onTap: () => _player.selectSubtitleTrack(t),
                          ),
                        for (final (i, sub) in _onlineChoices.indexed)
                          (
                            label:
                                '${TrackLabelBuilder.subtitleLabel(language: sub.language, index: i).primary} · online',
                            selected: false,
                            onTap: () => _addOnline(sub),
                          ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Media info',
                      icon: Icon(_showInfo ? Icons.info : Icons.info_outline, color: Colors.white),
                      onPressed: () => setState(() => _showInfo = !_showInfo),
                    ),
                    IconButton(
                      tooltip: _fullscreen ? 'Exit full screen' : 'Full screen',
                      icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
                      onPressed: () => _setFullscreen(!_fullscreen),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Online subtitles the menu offers: a few in the preferred languages,
  /// minus the ones already loaded (those are listed with the file's tracks).
  List<OnlineSubtitle> get _onlineChoices => [
    for (final sub in pickOnlineSubtitles(_online ?? const [], onlineSubtitleLanguages(_settings)))
      if (!_onlineAdded.contains(sub.url)) sub,
  ];

  Widget _trackMenu({
    required IconData icon,
    required String tooltip,
    required List<({String label, bool selected, Future<void> Function() onTap})> items,
  }) {
    return PopupMenuButton<int>(
      tooltip: tooltip,
      enabled: items.isNotEmpty,
      icon: Icon(icon, color: Colors.white),
      onOpened: _hideTimer?.cancel,
      onCanceled: _scheduleHide,
      onSelected: (i) {
        unawaited(items[i].onTap());
        _scheduleHide();
      },
      itemBuilder: (_) => [
        for (final (i, item) in items.indexed)
          CheckedPopupMenuItem(value: i, checked: item.selected, child: Text(item.label)),
      ],
    );
  }
}

IconData _backIcon(int s) => switch (s) {
  5 => Icons.replay_5,
  10 => Icons.replay_10,
  30 => Icons.replay_30,
  _ => Icons.replay,
};

IconData _forwardIcon(int s) => switch (s) {
  5 => Icons.forward_5,
  10 => Icons.forward_10,
  30 => Icons.forward_30,
  _ => Icons.fast_forward_rounded,
};

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, this.actions = const []});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in actions) Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: a),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
