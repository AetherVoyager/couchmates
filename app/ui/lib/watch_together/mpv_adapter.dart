import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;

import '../mpv/mpv.dart' as mpv;

/// Lets the watch party read and drive the mpv player.
final class MpvPartyAdapter extends owp.PlayerAdapter {
  MpvPartyAdapter(this.player);

  final mpv.Player player;

  @override
  int get positionMs => player.state.position.inMilliseconds;

  @override
  int? get durationMs {
    final d = player.state.duration.inMilliseconds;
    return d > 0 ? d : null;
  }

  @override
  bool get paused => !player.state.playing;

  @override
  bool get buffering => player.state.buffering;

  @override
  bool get firstFrameShown => player.state.hasRenderedFrame;

  @override
  bool get canSetRate => true;

  /// Seeks land on keyframes for most files.
  @override
  int get seekAccuracyMs => 2000;

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(int positionMs) => player.seek(Duration(milliseconds: positionMs));

  @override
  Future<void> setRate(double rate) => player.setRate(rate);
}

/// Learns a stream's length by opening it in a silent audio-only player.
Future<int?> probeDuration(Playable p, owp.Cancellation cancel) async {
  final player = mpv.Player.audio();
  try {
    await player.setProperty('aid', 'no');
    final duration = player.streams.duration.firstWhere((d) => d > Duration.zero);
    await player.open(mpv.Media(p.url, headers: p.headers.isEmpty ? null : p.headers), play: false);
    final found = await Future.any<Duration?>([
      duration,
      cancel.whenCancelled.then((_) => null),
      Future.delayed(const Duration(seconds: 20), () => null),
    ]);
    return found?.inMilliseconds;
  } catch (_) {
    return null;
  } finally {
    unawaited(player.dispose());
  }
}
