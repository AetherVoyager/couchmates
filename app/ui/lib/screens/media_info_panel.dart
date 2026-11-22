import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';

import '../mpv/mpv.dart' as mpv;

/// What mpv is playing, read from its properties once a second: the actual
/// video and audio formats, hardware decoding, bitrates and buffer.
class MediaInfoPanel extends StatefulWidget {
  const MediaInfoPanel({super.key, required this.player, required this.onClose});

  final mpv.Player player;
  final VoidCallback onClose;

  @override
  State<MediaInfoPanel> createState() => _MediaInfoPanelState();
}

class _MediaInfoPanelState extends State<MediaInfoPanel> {
  static const _props = [
    'video-codec',
    'width',
    'height',
    'estimated-vf-fps',
    'container-fps',
    'hwdec-current',
    'video-params/pixelformat',
    'video-params/gamma',
    'video-params/primaries',
    'video-bitrate',
    'audio-codec-name',
    'audio-params/hr-channels',
    'audio-params/channel-count',
    'audio-params/samplerate',
    'audio-bitrate',
    'file-format',
    'file-size',
    'demuxer-cache-duration',
    'frame-drop-count',
  ];

  final Map<String, String?> _values = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    final next = <String, String?>{};
    for (final p in _props) {
      try {
        final v = await widget.player.getProperty(p);
        next[p] = (v == null || v.isEmpty) ? null : v;
      } catch (_) {
        next[p] = null;
      }
    }
    if (mounted) setState(() => _values.addAll(next));
  }

  String? _v(String k) => _values[k];

  double? _num(String k) => double.tryParse(_v(k) ?? '');

  String? _bitrate(String k) {
    final bps = _num(k);
    if (bps == null || bps <= 0) return null;
    return bps >= 1e6 ? '${(bps / 1e6).toStringAsFixed(1)} Mbps' : '${(bps / 1e3).round()} kbps';
  }

  @override
  Widget build(BuildContext context) {
    final w = _v('width'), h = _v('height');
    final fps = _num('estimated-vf-fps') ?? _num('container-fps');
    final gamma = _v('video-params/gamma');
    final hdr = switch (gamma) {
      'pq' => 'HDR10 (PQ)',
      'hlg' => 'HLG',
      null => null,
      _ => 'SDR',
    };
    final hw = _v('hwdec-current');
    final channels = _v('audio-params/hr-channels') ?? _v('audio-params/channel-count');
    final rate = _num('audio-params/samplerate');
    final size = _num('file-size');
    final cache = _num('demuxer-cache-duration');
    final rows = <(String, String?)>[
      ('Video', _v('video-codec')),
      ('Resolution', w != null && h != null ? '$w × $h' : null),
      ('Frame rate', fps == null ? null : '${fps.toStringAsFixed(fps % 1 == 0 ? 0 : 3)} fps'),
      ('Dynamic range', hdr),
      ('Colour', [_v('video-params/pixelformat'), _v('video-params/primaries')].whereType<String>().join(' · ')),
      ('Decoding', hw == null || hw == 'no' ? 'Software' : 'Hardware ($hw)'),
      ('Video bitrate', _bitrate('video-bitrate')),
      ('Audio', _v('audio-codec-name')),
      ('Channels', channels),
      ('Sample rate', rate == null ? null : '${(rate / 1000).toStringAsFixed(1)} kHz'),
      ('Audio bitrate', _bitrate('audio-bitrate')),
      ('Container', _v('file-format')),
      ('File size', size == null ? null : formatBytes(size.round())),
      ('Buffered', cache == null ? null : '${cache.toStringAsFixed(0)} s ahead'),
      ('Dropped frames', _v('frame-drop-count')),
    ];
    return Container(
      width: 340,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(12)),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontSize: 13),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Media info', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  onPressed: widget.onClose,
                ),
              ],
            ),
            for (final (label, value) in rows)
              if (value != null && value.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 118,
                        child: Text(label, style: const TextStyle(color: Colors.white70)),
                      ),
                      Expanded(child: Text(value)),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
