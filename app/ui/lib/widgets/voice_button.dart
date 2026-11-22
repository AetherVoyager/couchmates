import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../watch_together/watch_together.dart';

/// The mic: mutes and unmutes in voice chat, or joins it when not in.
class VoiceButton extends StatelessWidget {
  const VoiceButton({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<WatchTogether>().voice;
    if (!voice.available || voice.room == null) return const SizedBox.shrink();
    return switch (voice.status) {
      VoiceStatus.connecting => const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      VoiceStatus.connected => IconButton.filledTonal(
        tooltip: voice.micError ?? (voice.micEnabled ? 'Mute' : 'Unmute'),
        isSelected: voice.micEnabled,
        icon: Icon(Icons.mic_off, color: voice.micError != null ? Colors.orange : null),
        selectedIcon: const Icon(Icons.mic),
        onPressed: () => voice.setMic(!voice.micEnabled),
      ),
      VoiceStatus.off || VoiceStatus.failed => IconButton(
        tooltip: voice.error ?? 'Join voice chat',
        icon: Icon(Icons.headset_mic_outlined, color: voice.status == VoiceStatus.failed ? Colors.orange : null),
        onPressed: voice.join,
      ),
    };
  }
}
