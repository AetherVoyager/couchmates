import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../watch_together/watch_together.dart';
import '../widgets/poster.dart';
import 'player_screen.dart';

/// Finds the streams for a movie or an episode, lets the user pick one when
/// there are several, and opens the player. Notices from the server (such
/// as "Limit Reached") are shown instead when nothing is playable.
///
/// [stream], [audioTrack] and [subtitleTrack] come from the details page's
/// pickers: the version to play without asking, and the tracks picked by hand.
Future<void> playTitle(
  BuildContext context, {
  required StremioMeta meta,
  StremioVideo? video,
  StremioStream? stream,
  int? audioTrack,
  int? subtitleTrack,
}) async {
  final catalog = context.read<HubSession>().catalog;
  if (catalog == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final watch = context.read<WatchTogether>();

  if (stream != null) {
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          playable: Playable(
            meta: meta,
            video: video,
            stream: stream,
            audioTrack: audioTrack,
            subtitleTrack: subtitleTrack,
          ),
        ),
      ),
    );
    return;
  }
  final StremioStreams result;
  try {
    result = await _withSpinner(context, catalog.streams(meta.type, video?.id ?? meta.id));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    return;
  }
  if (!context.mounted) return;
  if (result.streams.isEmpty && result.links.isNotEmpty) {
    await _pickLink(context, result.links);
    return;
  }
  if (result.streams.isEmpty) {
    final notice = result.notices.firstOrNull;
    messenger.showSnackBar(
      SnackBar(
        content: Text(notice == null ? 'No playable copy of this yet.' : [notice.name, ?notice.text].join('\n')),
      ),
    );
    return;
  }
  final picked = result.streams.length == 1 ? result.streams.single : await _pickStream(context, result.streams);
  if (picked == null) return;
  if (watch.room?.inRoom == true && watch.room?.isHost == false) {
    messenger.showSnackBar(
      const SnackBar(content: Text("You're in a watch party; only the host picks for the room. Playing just for you.")),
    );
  }
  await navigator.push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        playable: Playable(meta: meta, video: video, stream: picked),
      ),
    ),
  );
}

Future<T> _withSpinner<T>(BuildContext context, Future<T> work) async {
  final navigator = Navigator.of(context);
  var open = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    ).then((_) => open = false),
  );
  try {
    return await work;
  } finally {
    if (open) navigator.pop();
  }
}

Future<StremioStream?> _pickStream(BuildContext context, List<StremioStream> streams) {
  return showModalBottomSheet<StremioStream>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Choose a version', style: TextStyle(fontSize: 18)),
            ),
            for (final s in streams)
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(s.label),
                subtitle: Text(
                  [
                    ?s.source,
                    ?s.title?.split('\n').skip(1).join('  '),
                    if (s.sizeBytes != null) _size(s.sizeBytes!),
                  ].where((t) => t.isNotEmpty).join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop(s),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Nothing plays in the app, but add-ons know where else to watch it.
Future<void> _pickLink(BuildContext context, List<StremioLink> links) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text('Watch elsewhere', style: TextStyle(fontSize: 18)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('There\'s no copy to play here. These open in your browser or their app.'),
            ),
            for (final l in links)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text(l.name),
                subtitle: Text(
                  [?l.title?.replaceAll('\n', '  '), ?l.source].join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(launchUrl(l.url, mode: LaunchMode.externalApplication));
                },
              ),
          ],
        ),
      ),
    ),
  );
}

String _size(int bytes) {
  final gb = bytes / (1 << 30);
  return gb >= 1 ? '${gb.toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).round()} MB';
}
