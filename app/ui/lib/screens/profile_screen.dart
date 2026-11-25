import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/person_avatar.dart';
import 'settings/setting_tiles.dart';
import 'settings/trackers_screen.dart';
import 'settings_screen.dart';
import '../widgets/toasts.dart';

/// The round avatar in the top-right corner, opening a profile menu.
class ProfileButton extends StatelessWidget {
  const ProfileButton({super.key, this.showName = false});

  /// Shows the name next to the picture, for the expanded side pane.
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final user = session.config?.user;
    final theme = Theme.of(context);
    final name = user?.name ?? 'You';
    return PopupMenuButton<String>(
      tooltip: 'Profile',
      offset: const Offset(0, 48),
      onSelected: (choice) async {
        final navigator = Navigator.of(context);
        switch (choice) {
          case 'profile':
            unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const ProfileScreen())));
          case 'settings':
            unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())));
          case 'sign-out':
            await session.signOut();
            navigator.popUntil((r) => r.isFirst);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: PersonAvatar(id: user?.id ?? '', name: name, photo: user?.photo, size: 40),
            title: Text(name, style: theme.textTheme.titleSmall),
            subtitle: Text('@${user?.username ?? ''}'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'profile',
          child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.person_outline), title: Text('Profile')),
        ),
        const PopupMenuItem(
          value: 'settings',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.settings_outlined),
            title: Text('Settings'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'sign-out',
          child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.logout), title: Text('Sign out')),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PersonAvatar(id: user?.id ?? '', name: name, photo: user?.photo, size: 34),
            if (showName) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Text(name, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 18, color: theme.colorScheme.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }
}

/// The big avatar on the profile page, with a button to change the picture.
class _PhotoEditor extends StatelessWidget {
  const _PhotoEditor({required this.user, required this.busy, required this.onChange, required this.onRemove});

  final UserInfo user;
  final bool busy;
  final VoidCallback onChange;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 84,
      child: Stack(
        children: [
          PersonAvatar(id: user.id, name: user.name, photo: user.photo, size: 80),
          if (busy)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            child: PopupMenuButton<String>(
              tooltip: 'Change your picture',
              enabled: !busy,
              onSelected: (v) => v == 'remove' ? onRemove() : onChange(),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'change', child: Text('Choose a picture…')),
                if (user.photo != null) const PopupMenuItem(value: 'remove', child: Text('Remove picture')),
              ],
              child: Material(
                color: scheme.primary,
                shape: CircleBorder(side: BorderSide(color: scheme.surface, width: 3)),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.photo_camera_outlined, size: 16, color: scheme.onPrimary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// You: your name, your devices, your password and trackers, signing out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<Profile> _profile = context.read<HubSession>().profile();

  void _reload() => setState(() => _profile = context.read<HubSession>().profile());

  void _toast(String text) => toasts.show(text);

  bool _photoBusy = false;

  Future<void> _photo(Future<Profile> Function(HubSession session) change, String done) async {
    setState(() => _photoBusy = true);
    try {
      final updated = await change(context.read<HubSession>());
      if (!mounted) return;
      setState(() => _profile = Future.value(updated));
      _toast(done);
    } on HubException catch (e) {
      if (mounted) _toast(e.message);
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _choosePhoto() async {
    final file = await FilePicker.pickFile(dialogTitle: 'Choose a profile picture', type: FileType.image);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await _photo((s) => s.setPhoto(bytes), 'Profile picture changed.');
  }

  Future<void> _rename(String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(helperText: 'What others see in watch parties and voice chat'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || name.trim() == current || !mounted) return;
    try {
      final updated = await context.read<HubSession>().rename(name.trim());
      if (!mounted) return;
      setState(() => _profile = Future.value(updated));
      _toast('Name changed.');
    } on HubException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _signOutDevice(SignedInDevice d) async {
    try {
      await context.read<HubSession>().signOutDevice(d.id);
      _toast('${d.name} is signed out.');
      _reload();
    } on HubException catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: FutureBuilder<Profile>(
        future: _profile,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    snap.error is HubException ? (snap.error! as HubException).message : "Couldn't load your profile.",
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _reload, child: const Text('Try again')),
                ],
              ),
            );
          }
          final profile = snap.data!;
          final user = profile.user;
          final linked = session.trackers.where((t) => t.linked).map((t) => t.label).toList();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  Row(
                    children: [
                      _PhotoEditor(
                        user: user,
                        busy: _photoBusy,
                        onChange: _choosePhoto,
                        onRemove: () => _photo((s) => s.removePhoto(), 'Profile picture removed.'),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.name, style: theme.textTheme.headlineSmall),
                            Text(
                              '@${user.username ?? ''} · ${session.hub?.baseUrl.host ?? ''}',
                              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _rename(user.name),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Change name'),
                      ),
                    ],
                  ),
                  const SectionHeader('Signed in on'),
                  for (final d in profile.devices)
                    ListTile(
                      leading: Icon(d.current ? Icons.computer : Icons.devices_other_outlined),
                      title: Text(d.current ? '${d.name} (this device)' : d.name),
                      subtitle: Text('Signed in ${_ago(d.signedInAt)} · last used ${_ago(d.lastSeen)}'),
                      trailing: d.current
                          ? null
                          : TextButton(onPressed: () => _signOutDevice(d), child: const Text('Sign out')),
                    ),
                  const SectionHeader('Account'),
                  ListTile(
                    leading: const Icon(Icons.password),
                    title: const Text('Change password'),
                    subtitle: const Text('Signs you out on your other devices'),
                    onTap: () async {
                      await showDialog<void>(context: context, builder: (_) => const ChangePasswordDialog());
                      _reload();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.track_changes),
                    title: const Text('Trackers'),
                    subtitle: Text(linked.isEmpty ? 'Not linked' : 'Linked: ${linked.join(', ')}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Trackers')),
                          body: ListView(children: const [TrackersSection()]),
                        ),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.record_voice_over_outlined),
                    title: const Text('Voice chat'),
                    subtitle: Text(session.voiceAvailable ? 'Available in watch parties' : 'Not set up on your Hub'),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: () async {
                        final navigator = Navigator.of(context);
                        await session.signOut();
                        navigator.popUntil((r) => r.isFirst);
                      },
                      icon: const Icon(Icons.logout),
                      label: const Text('Sign out of this device'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} days ago';
  return '${t.day}/${t.month}/${t.year}';
}

/// Change password: needs the current one; signs out other devices.
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key});

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<HubSession>().changePassword(current: _current.text, next: _next.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      toasts.success('Password changed.');
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
              validator: (v) => (v ?? '').isEmpty ? 'Enter your current password.' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
              validator: (v) => passwordProblem(v ?? ''),
              onFieldSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Change')),
      ],
    );
  }
}
