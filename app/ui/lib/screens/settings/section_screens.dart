import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme.dart';
import 'setting_tiles.dart';

class FriendsSection extends StatelessWidget {
  const FriendsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchSetting(
          setting: Settings.showBubble,
          title: "Show the who's-watching bubble",
          subtitle: 'In the bottom-right corner. When it is hidden, requests to join still pop up.',
        ),
        SwitchSetting(
          setting: Settings.bubbleInPlayer,
          title: 'Show it in the player too',
          subtitle: 'Only while the player controls are showing.',
        ),
        SwitchSetting(
          setting: Settings.shareActivity,
          title: "Share what I'm watching",
          subtitle: 'Others on your Hub see the title and can ask to join you. Your room code stays private.',
        ),
      ],
    );
  }
}

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final accent = settings.get(Settings.accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ChoiceSetting<String>(
          setting: Settings.theme,
          title: 'Theme',
          icon: Icons.contrast,
          choices: [
            ('dark', 'Dark'),
            ('black', 'Black (for OLED screens)'),
            ('light', 'Light'),
            ('system', 'Follow the system'),
          ],
        ),
        const SectionHeader('Accent color'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (name, value) in accentChoices)
                Tooltip(
                  message: name,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => settings.set(Settings.accent, value),
                    child: CircleAvatar(
                      radius: 20,
                      backgroundColor: Color(value),
                      child: value == accent ? const Icon(Icons.check, color: Colors.white) : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const ChoiceSetting<String>(
          setting: Settings.posterSize,
          title: 'Poster size',
          icon: Icons.photo_size_select_large,
          choices: [('small', 'Small'), ('medium', 'Medium'), ('large', 'Large')],
        ),
      ],
    );
  }
}

class PlaybackSection extends StatelessWidget {
  const PlaybackSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader('Languages'),
        LanguagesSetting(setting: Settings.audioLanguages, title: 'Audio language', emptyLabel: "The file's default"),
        LanguagesSetting(
          setting: Settings.subtitleLanguages,
          title: 'Subtitle language',
          emptyLabel: 'Same as the audio languages',
        ),
        ChoiceSetting<String>(
          setting: Settings.subtitleMode,
          title: 'Show subtitles',
          choices: [
            ('auto', "When the audio isn't in your languages"),
            ('always', 'Always'),
            ('off', 'Never (turn on by hand)'),
          ],
        ),
        SwitchSetting(
          setting: Settings.onlineSubtitles,
          title: 'Find subtitles online',
          subtitle:
              'Adds subtitles from OpenSubtitles (or the Hub\'s subtitle add-ons) when the file has none in your language',
        ),
        ChoiceSetting<int>(
          setting: Settings.subtitleSize,
          title: 'Subtitle size',
          choices: [
            (70, 'Smallest'),
            (85, 'Small'),
            (100, 'Normal'),
            (120, 'Large'),
            (140, 'Larger'),
            (170, 'Largest'),
          ],
        ),
        SectionHeader('Playback'),
        SwitchSetting(
          setting: Settings.resume,
          title: 'Resume where you left off',
          subtitle: 'Starts movies and episodes from where you stopped',
        ),
        SwitchSetting(
          setting: Settings.autoplayNext,
          title: 'Play the next episode',
          subtitle: 'When an episode ends, starts the next one',
        ),
        ChoiceSetting<int>(
          setting: Settings.defaultVolume,
          title: 'Starting volume',
          choices: [(25, '25%'), (50, '50%'), (75, '75%'), (100, '100%')],
        ),
        SwitchSetting(
          setting: Settings.hardwareDecoding,
          title: 'Hardware decoding',
          subtitle: 'Uses the graphics card. Turn off if video stutters or shows green frames.',
        ),
      ],
    );
  }
}

class ControlsSection extends StatelessWidget {
  const ControlsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final back = settings.get(Settings.seekBack);
    final forward = settings.get(Settings.seekForward);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ChoiceSetting<int>(
          setting: Settings.seekBack,
          title: 'Skip back',
          choices: [(5, '5 seconds'), (10, '10 seconds'), (15, '15 seconds'), (30, '30 seconds')],
        ),
        const ChoiceSetting<int>(
          setting: Settings.seekForward,
          title: 'Skip forward',
          choices: [(10, '10 seconds'), (15, '15 seconds'), (30, '30 seconds'), (60, '1 minute'), (90, '90 seconds')],
        ),
        const ChoiceSetting<int>(
          setting: Settings.hideAfter,
          title: 'Hide the controls after',
          choices: [(2, '2 seconds'), (3, '3 seconds'), (5, '5 seconds'), (8, '8 seconds')],
        ),
        const SwitchSetting(setting: Settings.doubleClickFullscreen, title: 'Double-click for full screen'),
        const SectionHeader('Keyboard'),
        for (final (keys, what) in [
          ('Space or K', 'Play or pause'),
          ('← or J', 'Back $back seconds'),
          ('→ or L', 'Forward $forward seconds'),
          ('↑ / ↓', 'Volume up / down'),
          ('M', 'Mute'),
          ('F', 'Full screen'),
          ('N', 'Next episode'),
          ('I', 'Media info'),
          ('Esc', 'Leave full screen, or close the player'),
        ])
          ListTile(
            dense: true,
            leading: SizedBox(
              width: 90,
              child: Text(keys, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            title: Text(what),
          ),
      ],
    );
  }
}
