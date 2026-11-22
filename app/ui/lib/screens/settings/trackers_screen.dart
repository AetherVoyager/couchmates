import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Link Trakt or Simkl so what you watch is recorded there.
class TrackersSection extends StatefulWidget {
  const TrackersSection({super.key});

  @override
  State<TrackersSection> createState() => _TrackersSectionState();
}

class _TrackersSectionState extends State<TrackersSection> {
  @override
  void initState() {
    super.initState();
    unawaited(context.read<HubSession>().loadTrackers());
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final available = session.trackers.where((t) => t.available).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Link an account and Couchmates records what you watch there (scrobbling), including in watch parties.',
          ),
        ),
        if (available.isEmpty)
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('No trackers are set up on your Hub'),
            subtitle: Text('Your admin can turn on Trakt or Simkl in the Hub\'s settings.'),
          ),
        for (final t in available)
          ListTile(
            leading: const Icon(Icons.track_changes),
            title: Text(t.label),
            subtitle: Text(t.linked ? 'Linked${t.username == null ? '' : ' as ${t.username}'}' : 'Not linked'),
            trailing: t.linked
                ? OutlinedButton(
                    onPressed: () async {
                      try {
                        await session.unlinkTracker(t.service);
                      } on HubException catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
                        }
                      }
                    },
                    child: const Text('Unlink'),
                  )
                : FilledButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => _LinkDialog(tracker: t),
                    ),
                    child: const Text('Link'),
                  ),
          ),
      ],
    );
  }
}

/// Shows the code to enter on the tracker's site and waits for it.
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.tracker});

  final TrackerStatus tracker;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  TrackerLinkStart? _start;
  String? _error;
  String? _done;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    final session = context.read<HubSession>();
    try {
      final start = await session.startTrackerLink(widget.tracker.service);
      if (!mounted) return;
      setState(() => _start = start);
      _timer = Timer.periodic(Duration(seconds: start.interval.clamp(2, 30)), (_) => _poll(session));
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _poll(HubSession session) async {
    try {
      final poll = await session.pollTrackerLink(widget.tracker.service);
      if (!mounted) return;
      switch (poll.status) {
        case 'linked':
          _timer?.cancel();
          setState(() => _done = 'Linked${poll.username == null ? '' : ' as ${poll.username}'}.');
        case 'expired':
          _timer?.cancel();
          setState(() => _error = 'The code expired. Close this and try again.');
        case 'denied':
          _timer?.cancel();
          setState(() => _error = 'Linking was declined on ${widget.tracker.label}.');
      }
    } on HubException catch (e) {
      _timer?.cancel();
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = _start;
    return AlertDialog(
      title: Text('Link ${widget.tracker.label}'),
      content: SizedBox(
        width: 380,
        child: _done != null
            ? Text(_done!)
            : _error != null
            ? Text(_error!, style: TextStyle(color: theme.colorScheme.error))
            : start == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('1. Open ${start.verificationUrl}'),
                  const SizedBox(height: 4),
                  const Text('2. Sign in and enter this code:'),
                  const SizedBox(height: 12),
                  Center(
                    child: SelectableText(
                      start.userCode,
                      style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    children: [
                      SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Waiting for you to enter it…'),
                    ],
                  ),
                ],
              ),
      ),
      actions: [
        if (start != null && _done == null && _error == null) ...[
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: start.userCode)),
            child: const Text('Copy code'),
          ),
          FilledButton(
            onPressed: () => launchUrl(Uri.parse(start.verificationUrl), mode: LaunchMode.externalApplication),
            child: const Text('Open site'),
          ),
        ],
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(_done != null ? 'Done' : 'Close')),
      ],
    );
  }
}
