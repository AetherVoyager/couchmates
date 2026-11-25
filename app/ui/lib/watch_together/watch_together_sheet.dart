import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;
import 'package:provider/provider.dart';

import '../widgets/voice_button.dart';
import 'watch_together.dart';
import '../widgets/toasts.dart';

Future<void> showWatchTogetherSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => const _WatchTogetherSheet(),
);

/// Start or join a room; once in one, its code, who's there and voice.
class _WatchTogetherSheet extends StatefulWidget {
  const _WatchTogetherSheet();

  @override
  State<_WatchTogetherSheet> createState() => _WatchTogetherSheetState();
}

class _WatchTogetherSheetState extends State<_WatchTogetherSheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = partyErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final watch = context.watch<WatchTogether>();
    final room = watch.room;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: room == null || !room.inRoom ? _start(theme, watch) : _inRoom(theme, watch, room),
        ),
      ),
    );
  }

  Widget _start(ThemeData theme, WatchTogether watch) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Watch together', style: theme.textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Start a room and share its code. Whatever you play is played for everyone, in sync, with voice chat.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _busy ? null : () => _run(() => watch.create()),
          icon: const Icon(Icons.add),
          label: const Text('Start a room'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _code,
                decoration: const InputDecoration(labelText: 'Room code', hintText: 'K7M-Q2X'),
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                onSubmitted: (_) => _run(() => watch.join(_code.text)),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(() => watch.join(_code.text)),
              style: OutlinedButton.styleFrom(minimumSize: const Size(96, 56)),
              child: const Text('Join'),
            ),
          ],
        ),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Widget _inRoom(ThemeData theme, WatchTogether watch, WatchRoom room) {
    final voice = watch.voice;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Watch party', style: theme.textTheme.titleLarge)),
            if (room.isHost) const Chip(label: Text("You're the host")),
          ],
        ),
        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            Clipboard.setData(ClipboardData(text: room.code ?? ''));
            toasts.success('Room code copied');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.primary),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                SelectableText(
                  room.code ?? '…',
                  style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w600),
                ),
                Text('Tap to copy, then send it to your friends', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          room.isHost
              ? (room.state.media == null
                    ? 'Play something and everyone here will watch it with you.'
                    : 'Playing for everyone.')
              : (room.state.media == null ? 'Waiting for the host to play something.' : _matchText(room)),
          style: theme.textTheme.bodyMedium,
        ),
        if (!room.isHost && watch.choiceDismissed) ...[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () {
              Navigator.of(context).maybePop();
              watch.openChoice();
            },
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Back to the party'),
          ),
        ],
        const SizedBox(height: 12),
        for (final p in room.people) _person(theme, room, p, voice.memberForPeer(p.peerId, p.name)),
        const Divider(height: 24),
        Row(
          children: [
            const VoiceButton(),
            const SizedBox(width: 8),
            Expanded(child: Text(_voiceText(voice), style: theme.textTheme.bodyMedium)),
            TextButton.icon(onPressed: () => watch.leave(), icon: const Icon(Icons.logout), label: const Text('Leave')),
          ],
        ),
        if (voice.connected) _VoiceCheck(voice: voice),
      ],
    );
  }

  Widget _person(ThemeData theme, WatchRoom room, owp.Participant p, VoiceMember? voice) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(child: Text(p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase())),
    title: Text('${p.name}${p.peerId == room.state.peerId ? ' (you)' : ''}'),
    subtitle: Text([if (p.host) 'Host', if (!p.connected) 'Reconnecting…', p.player.name].join(' · ')),
    trailing: voice == null
        ? null
        : Icon(
            voice.muted ? Icons.mic_off : (voice.speaking ? Icons.graphic_eq : Icons.mic),
            color: voice.speaking ? theme.colorScheme.primary : null,
          ),
  );

  String _matchText(WatchRoom room) => switch (room.state.match?.state) {
    null || owp.MatchState.searching => 'Finding your copy…',
    owp.MatchState.matched => 'Watching ${room.state.media?.title ?? ''} together.',
    owp.MatchState.mismatched => 'Your copy is a different length. Open the player to decide.',
    owp.MatchState.unavailable => "You don't have this one in your catalog.",
  };

  String _voiceText(VoiceChat voice) {
    if (!voice.available) return 'Voice chat is off on this Hub.';
    return switch (voice.status) {
      VoiceStatus.off => 'Not in voice chat.',
      VoiceStatus.connecting => 'Joining voice chat…',
      VoiceStatus.connected =>
        voice.micError ?? (voice.micEnabled ? 'You can be heard.' : 'Muted. Tap the mic to talk.'),
      VoiceStatus.failed => voice.error ?? "Voice chat didn't connect.",
    };
  }
}

/// Proof that voice works: your mic's live level, and for everyone else
/// whether their audio reaches this device and when they speak.
class _VoiceCheck extends StatefulWidget {
  const _VoiceCheck({required this.voice});

  final VoiceChat voice;

  @override
  State<_VoiceCheck> createState() => _VoiceCheckState();
}

class _VoiceCheckState extends State<_VoiceCheck> {
  late final Timer _tick;
  double _peak = 0;

  @override
  void initState() {
    super.initState();
    // Levels change without events, so redraw a few times a second.
    _tick = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      setState(() => _peak = (widget.voice.micLevel > _peak ? widget.voice.micLevel : _peak * 0.85));
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final voice = widget.voice;
    final others = voice.members.where((m) => !m.isLocal).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Voice check', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(voice.micEnabled ? Icons.mic : Icons.mic_off, size: 18),
              const SizedBox(width: 8),
              const Text('Your mic'),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: voice.micEnabled ? _peak.clamp(0, 1).toDouble() : 0,
                    minHeight: 8,
                    color: Colors.greenAccent.shade400,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              voice.micEnabled ? 'Talk: the bar should move.' : 'Unmute to test your mic.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          if (others.isEmpty)
            Text('Nobody else is in voice yet.', style: theme.textTheme.bodySmall)
          else
            for (final m in others)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      m.speaking ? Icons.graphic_eq : (m.muted ? Icons.mic_off : Icons.mic),
                      size: 18,
                      color: m.speaking ? Colors.greenAccent.shade400 : null,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(m.name, overflow: TextOverflow.ellipsis)),
                    SizedBox(
                      width: 150,
                      child: Tooltip(
                        message: "${m.name}'s volume: ${(voice.personVolume(m.person) * 100).round()}%",
                        child: Slider(
                          value: voice.personVolume(m.person),
                          max: 2,
                          divisions: 20,
                          onChanged: (v) => voice.setPersonVolume(m.person, v),
                        ),
                      ),
                    ),
                    Text(
                      m.muted
                          ? 'muted'
                          : m.receiving
                          ? (m.speaking ? 'speaking' : 'audio reaching you')
                          : 'no audio yet',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: !m.muted && !m.receiving ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
