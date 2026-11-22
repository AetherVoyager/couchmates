import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'setting_tiles.dart';

/// Microphone, voice volume, lowering the movie, and a word on Bluetooth.
class VoiceSection extends StatefulWidget {
  const VoiceSection({super.key});

  @override
  State<VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends State<VoiceSection> {
  late Future<List<MicDevice>> _mics = listMicrophones();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final selected = settings.get(Settings.voiceMic);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<List<MicDevice>>(
          future: _mics,
          builder: (context, snap) {
            final mics = snap.data ?? const <MicDevice>[];
            final current = mics.where((m) => m.id == selected).firstOrNull;
            return ListTile(
              leading: const Icon(Icons.mic_none),
              title: const Text('Microphone'),
              subtitle: Text(current?.label ?? 'System default'),
              trailing: IconButton(
                tooltip: 'Look for microphones again',
                icon: const Icon(Icons.refresh),
                onPressed: () => setState(() => _mics = listMicrophones()),
              ),
              onTap: () async {
                final picked = await showDialog<String>(
                  context: context,
                  builder: (context) => SimpleDialog(
                    title: const Text('Microphone for voice chat'),
                    children: [
                      for (final (id, label) in [('', 'System default'), for (final m in mics) (m.id, m.label)])
                        ListTile(
                          leading: Icon(id == selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                          title: Text(label),
                          onTap: () => Navigator.of(context).pop(id),
                        ),
                    ],
                  ),
                );
                if (picked != null) await settings.set(Settings.voiceMic, picked);
              },
            );
          },
        ),
        const ChoiceSetting<int>(
          setting: Settings.voiceVolume,
          title: "Everyone's voice volume",
          icon: Icons.record_voice_over_outlined,
          subtitle: 'Each person can also be set in the watch party',
          choices: [(25, '25%'), (50, '50%'), (75, '75%'), (100, '100%'), (125, '125%'), (150, '150%'), (200, '200%')],
        ),
        const ChoiceSetting<int>(
          setting: Settings.duckMovie,
          title: 'Lower the movie while people talk',
          icon: Icons.volume_down_outlined,
          choices: [
            (0, 'Never'),
            (25, 'A little (25%)'),
            (40, 'Some (40%)'),
            (60, 'A lot (60%)'),
            (80, 'Almost silent (80%)'),
          ],
        ),
        const SwitchSetting(
          setting: Settings.joinMuted,
          title: 'Join voice chat muted',
          subtitle: 'Your microphone stays closed until you unmute',
        ),
        Card(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bluetooth_audio),
                    const SizedBox(width: 8),
                    Text('Bluetooth headsets', style: theme.textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  "Most Bluetooth headsets can't play stereo and use their microphone at the same time. When an app "
                  "opens the headset's mic, Windows switches it to 'hands-free' mode, and everything, the movie "
                  'included, sounds like a phone call until the mic closes.\n\n'
                  'For the best movie sound: keep the headset for listening and pick another microphone above '
                  "(the laptop's or a webcam's). Or stay muted when not talking: Couchmates doesn't open the mic "
                  "while you're muted. Newer LE Audio headsets on Windows 11 don't have this problem.",
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
