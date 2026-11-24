import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../chat/app_chat.dart';
import '../chat/chat_view.dart';
import '../widgets/person_avatar.dart';
import '../widgets/poster.dart';
import 'friends.dart';

/// The floating bubble in the bottom-right corner over every screen: who's
/// watching what, and asking to join. Tapping it opens a panel above it.
///
/// The panel's header switches between who's watching ([_ActivityView]) and
/// the chat ([ChatView]).
class FriendsBubble extends StatefulWidget {
  const FriendsBubble({super.key, required this.child});

  /// The app (the navigator) the bubble floats over.
  final Widget child;

  @override
  State<FriendsBubble> createState() => _FriendsBubbleState();
}

class _FriendsBubbleState extends State<FriendsBubble> {
  bool _open = false;
  int _seenAsks = 0;
  int _seenChatOpens = 0;
  bool _hover = false;

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final signedIn = context.select<HubSession, bool>((s) => s.status == SessionStatus.signedIn);
    final show = context.select<AppSettings, bool>((s) => s.get(Settings.showBubble));
    final link = context.watch<FriendsLink>();
    final presence = link.presence;

    final chat = context.watch<AppChat>();

    // Someone asked to join: open so the answer is one click away.
    if (link.askedCount != _seenAsks) {
      _seenAsks = link.askedCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        chat.showing = false;
        if (!_open) setState(() => _open = true);
      });
    }
    // Something asked for a chat (such as Message on a friend).
    if (chat.openRequests != _seenChatOpens) {
      _seenChatOpens = chat.openRequests;
      if (!_open) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() => _open = true) : null);
    }

    final inPlayer = context.select<AppSettings, bool>((s) => s.get(Settings.bubbleInPlayer));
    // Over a movie: only with the player's controls, unless someone is
    // asking to join or the panel is open.
    final hiddenInPlayer =
        link.playerOpen && !_open && presence.incoming.isEmpty && (!inPlayer || !link.playerControls);
    final visible = signedIn && show;
    final bottom = link.playerOpen ? 112.0 : 20.0;
    final size = MediaQuery.sizeOf(context);
    final panelWidth = (size.width - 32).clamp(0.0, 360.0);
    final panelHeight = (size.height - bottom - 96).clamp(0.0, 520.0);

    return Stack(
      children: [
        widget.child,
        if (visible && _open)
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _toggle, child: const SizedBox.expand()),
          ),
        if (visible)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            right: 20,
            bottom: bottom + 68,
            child: IgnorePointer(
              ignoring: !_open,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: ScaleTransition(
                    scale: Tween(begin: 0.92, end: 1.0).animate(a),
                    alignment: Alignment.bottomRight,
                    child: child,
                  ),
                ),
                child: _open
                    ? SizedBox(
                        key: const ValueKey('panel'),
                        width: panelWidth,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: panelHeight),
                          // The bubble sits above the navigator, so the panel brings
                          // its own overlay for tooltips, text selection and pickers.
                          child: Overlay.wrap(alwaysSizeToContent: true, child: _Panel(onClose: _toggle)),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              ),
            ),
          ),
        if (visible)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            right: 20,
            bottom: bottom,
            child: IgnorePointer(
              ignoring: hiddenInPlayer,
              child: MouseRegion(
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: hiddenInPlayer
                      ? 0
                      : link.playerOpen && !_open && !_hover && presence.incoming.isEmpty
                      ? 0.7
                      : 1,
                  child: _Bubble(
                    open: _open,
                    watching: presence.watchingCount,
                    asking: presence.incoming.length,
                    unread: chat.unread,
                    onTap: _toggle,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.open,
    required this.watching,
    required this.asking,
    required this.unread,
    required this.onTap,
  });

  final bool open;
  final int watching;
  final int asking;

  /// Unread chat messages.
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = asking > 0
        ? '$asking asking to join'
        : unread > 0
        ? '$unread unread messages'
        : watching > 0
        ? '$watching watching now'
        : "Who's watching";
    return Semantics(
      button: true,
      label: label,
      child: Badge(
        isLabelVisible: !open && (asking > 0 || unread > 0 || watching > 0),
        backgroundColor: asking > 0
            ? scheme.error
            : unread > 0
            ? scheme.tertiary
            : const Color(0xFF3ECF8E),
        textColor: asking > 0
            ? scheme.onError
            : unread > 0
            ? scheme.onTertiary
            : Colors.black,
        label: Text(
          asking > 0
              ? '$asking'
              : unread > 0
              ? (unread > 99 ? '99+' : '$unread')
              : '$watching',
        ),
        offset: const Offset(-2, 2),
        child: Material(
          color: open ? scheme.primary : scheme.primaryContainer,
          shape: const CircleBorder(),
          elevation: 6,
          shadowColor: Colors.black54,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: 56,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: Icon(
                  open ? Icons.close_rounded : Icons.live_tv_rounded,
                  key: ValueKey(open),
                  color: open ? scheme.onPrimary : scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final link = context.watch<FriendsLink>();
    final chat = context.watch<AppChat>();
    final presence = link.presence;
    final online = presence.friends.where((f) => f.online).length;
    final summary = presence.offline
        ? "Can't reach the Hub right now"
        : !presence.loaded
        ? 'Looking around…'
        : [if (presence.watchingCount > 0) '${presence.watchingCount} watching', '$online online'].join(' · ');
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 12,
      shadowColor: Colors.black87,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Tab(label: 'Watching', selected: !chat.showing, onTap: () => chat.showing = false),
                    const SizedBox(width: 6),
                    _Tab(label: 'Chat', selected: chat.showing, count: chat.unread, onTap: () => chat.showing = true),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close_rounded, size: 20), onPressed: onClose),
                  ],
                ),
                if (!chat.showing)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 2),
                    child: Text(summary, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          if (chat.showing)
            const Expanded(child: ChatView())
          else ...[
            const Flexible(child: _ActivityView()),
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
            const _ShareSwitch(),
          ],
        ],
      ),
    );
  }
}

/// A header tab: Watching or Chat, with an unread count.
class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, required this.onTap, this.count = 0});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Badge(
                  label: Text(count > 99 ? '99+' : '$count'),
                  backgroundColor: scheme.tertiary,
                  textColor: scheme.onTertiary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareSwitch extends StatelessWidget {
  const _ShareSwitch();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final share = settings.get(Settings.shareActivity);
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => settings.set(Settings.shareActivity, !share),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 10, 6),
        child: Row(
          children: [
            Icon(share ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                share ? 'Others can see what you watch' : 'What you watch is hidden from friends',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Transform.scale(
              scale: 0.8,
              child: Switch(value: share, onChanged: (v) => settings.set(Settings.shareActivity, v)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Requests to join, then everyone else on the Hub.
class _ActivityView extends StatefulWidget {
  const _ActivityView();

  @override
  State<_ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<_ActivityView> {
  final Map<String, Future<String?>> _posters = {};

  /// The poster from this user's own catalog: friends' links can carry
  /// their tokens, so the Hub never passes them on.
  Future<String?> _poster(FriendWatching w) {
    final catalog = context.read<HubSession>().catalog;
    if (catalog == null) return Future.value();
    return _posters.putIfAbsent(
      '${w.metaType}/${w.metaId}',
      () => catalog.meta(w.metaType, w.metaId).then((m) => m?.poster, onError: (Object _) => null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final link = context.watch<FriendsLink>();
    final presence = link.presence;
    final incoming = presence.incoming;
    final friends = presence.friends;
    final theme = Theme.of(context);

    if (presence.loaded && friends.isEmpty && incoming.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.weekend_outlined, size: 36, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text('Nobody else is here yet', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Friends show up once they open Couchmates.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final r in incoming) _AskCard(request: r, busy: link.busy.contains(r.id)),
        for (final f in friends) _FriendTile(friend: f, poster: f.watching == null ? null : _poster(f.watching!)),
      ],
    );
  }
}

class _AskCard extends StatelessWidget {
  const _AskCard({required this.request, required this.busy});

  final JoinRequest request;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final link = context.read<FriendsLink>();
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 6),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PersonAvatar(id: request.person.id, name: request.person.name, photo: request.person.photo, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: request.person.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(text: ' wants to join you for '),
                      TextSpan(
                        text: request.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: busy ? null : () => unawaited(link.decline(request)), child: const Text('Not now')),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: busy ? null : () => unawaited(link.accept(request)),
                icon: busy
                    ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check_rounded, size: 18),
                label: const Text('Let in'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({required this.friend, this.poster});

  final FriendActivity friend;
  final Future<String?>? poster;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final w = friend.watching;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          PersonAvatar(
            id: friend.person.id,
            name: friend.person.name,
            photo: friend.person.photo,
            online: friend.online,
            size: 38,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  friend.person.name,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (w == null)
                  Text(friend.online ? 'Online' : 'Seen ${_ago(friend.lastSeen)}', style: muted)
                else ...[
                  Row(
                    children: [
                      Icon(
                        w.paused ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 14,
                        color: w.paused ? scheme.onSurfaceVariant : const Color(0xFF3ECF8E),
                      ),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          w.title,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    [?w.episode, if (w.inParty) 'watch party', _ago(w.since, suffix: false)].join(' · '),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  _JoinButton(friend: friend),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Message ${friend.person.name}',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
            onPressed: () => context.read<AppChat>().openWith(friend.person),
          ),
          if (w != null) ...[
            const SizedBox(width: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 40,
                height: 60,
                child: FutureBuilder<String?>(future: poster, builder: (_, snap) => NetImage(snap.data)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _JoinButton extends StatelessWidget {
  const _JoinButton({required this.friend});

  final FriendActivity friend;

  @override
  Widget build(BuildContext context) {
    final link = context.watch<FriendsLink>();
    final request = link.presence.requestTo(friend.person.id);
    final busy = link.busy.contains(friend.person.id);
    const dense = VisualDensity(horizontal: -2, vertical: -3);
    final small = ButtonStyle(
      visualDensity: dense,
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelMedium),
    );
    if (busy || request?.accepted == true) {
      return FilledButton.tonalIcon(
        style: small,
        onPressed: null,
        icon: const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text(request?.accepted == true ? 'Joining…' : 'Asking…'),
      );
    }
    if (request != null && request.pending) {
      return OutlinedButton.icon(
        style: small,
        onPressed: () => unawaited(link.cancel(request)),
        icon: const Icon(Icons.hourglass_top_rounded, size: 14),
        label: const Text('Asked · Cancel'),
      );
    }
    return FilledButton.tonalIcon(
      style: small,
      onPressed: () => unawaited(link.ask(friend.person)),
      icon: const Icon(Icons.login_rounded, size: 14),
      label: Text(request?.declined == true ? 'Ask again' : 'Ask to join'),
    );
  }
}

String _ago(DateTime then, {bool suffix = true}) {
  final d = DateTime.now().difference(then);
  final text = d.inMinutes < 1
      ? (suffix ? 'just now' : 'just started')
      : d.inMinutes < 60
      ? '${d.inMinutes} min'
      : d.inHours < 24
      ? '${d.inHours} h'
      : '${d.inDays} d';
  if (d.inMinutes < 1) return text;
  return suffix ? '$text ago' : 'for $text';
}
