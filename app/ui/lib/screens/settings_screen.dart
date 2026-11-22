import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../services/updater.dart';
import 'settings/section_screens.dart';
import 'settings/setting_tiles.dart';
import 'settings/trackers_screen.dart';
import 'settings/voice_section.dart';

enum SettingsSection {
  appearance('Appearance', 'Theme, accent color, poster size', Icons.palette_outlined),
  playback('Video playback', 'Languages, subtitles, resume, next episode', Icons.movie_outlined),
  controls('Player controls', 'Skip steps, auto-hide, keyboard', Icons.gamepad_outlined),
  voice('Voice chat', 'Microphone, volume, lowering the movie', Icons.headset_mic_outlined),
  friends('Friends', "The who's-watching bubble, sharing what you watch", Icons.live_tv_outlined),
  trackers('Trackers', 'Trakt, Simkl', Icons.track_changes),
  general('Updates', 'Version, automatic checks', Icons.system_update_alt);

  const SettingsSection(this.title, this.subtitle, this.icon);

  final String title;
  final String subtitle;
  final IconData icon;
}

Widget _sectionBody(SettingsSection section) => switch (section) {
  SettingsSection.appearance => const AppearanceSection(),
  SettingsSection.playback => const PlaybackSection(),
  SettingsSection.controls => const ControlsSection(),
  SettingsSection.voice => const VoiceSection(),
  SettingsSection.friends => const FriendsSection(),
  SettingsSection.trackers => const TrackersSection(),
  SettingsSection.general => const _GeneralSection(),
};

/// Sections beside their settings on wide windows; a list that opens each
/// section on narrow ones.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsSection _selected = SettingsSection.appearance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 860) {
            return ListView(
              children: [
                for (final s in SettingsSection.values)
                  ListTile(
                    leading: Icon(s.icon),
                    title: Text(s.title),
                    subtitle: Text(s.subtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: Text(s.title)),
                          body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [_sectionBody(s)]),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 300,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  children: [
                    for (final s in SettingsSection.values)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          selected: s == _selected,
                          selectedTileColor: theme.colorScheme.secondaryContainer,
                          leading: Icon(s.icon),
                          title: Text(s.title),
                          subtitle: Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => setState(() => _selected = s),
                        ),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: ListView(
                  key: PageStorageKey(_selected),
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(_selected.title, style: theme.textTheme.headlineSmall),
                    ),
                    _sectionBody(_selected),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GeneralSection extends StatelessWidget {
  const _GeneralSection();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _UpdatesTile(),
        SwitchSetting(setting: Settings.checkUpdates, title: 'Check for updates when Couchmates starts'),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('Your name, devices, password and sign-out are in Profile (your picture, top right).'),
        ),
      ],
    );
  }
}

class _UpdatesTile extends StatefulWidget {
  const _UpdatesTile();

  @override
  State<_UpdatesTile> createState() => _UpdatesTileState();
}

class _UpdatesTileState extends State<_UpdatesTile> {
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _version = i.version);
    });
  }

  @override
  Widget build(BuildContext context) {
    final updater = context.watch<Updater>();
    final info = updater.info;
    final String status;
    if (Updater.platform == null) {
      status = 'Updates install by themselves on Windows only.';
    } else if (updater.checking) {
      status = 'Checking…';
    } else if (updater.progress != null) {
      status = 'Downloading… ${(updater.progress! * 100).round()}%';
    } else if (updater.error != null) {
      status = updater.error!;
    } else if (info == null) {
      status = 'Not checked yet';
    } else if (!info.available) {
      status = "Your Hub doesn't offer updates yet.";
    } else if (info.newer) {
      status = 'Couchmates ${info.latestVersion} is available.';
    } else {
      status = "You're up to date.";
    }
    return ListTile(
      leading: const Icon(Icons.system_update_alt),
      title: Text('Couchmates ${_version ?? ''}'),
      subtitle: Text(status),
      trailing: Updater.platform == null
          ? null
          : info?.newer == true
          ? FilledButton(onPressed: updater.progress == null ? updater.install : null, child: const Text('Update'))
          : OutlinedButton(onPressed: updater.checking ? null : updater.check, child: const Text('Check now')),
    );
  }
}
