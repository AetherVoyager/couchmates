import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../watch_together/friends.dart';
import '../widgets/person_avatar.dart';
import 'app_chat.dart';
import 'verified_name.dart';

/// The bubble's chat tab: the list of chats, or one conversation.
class ChatView extends StatelessWidget {
  const ChatView({super.key});

  @override
  Widget build(BuildContext context) {
    final selected = context.select<AppChat, String?>((c) => c.selected);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      child: selected == null ? const _ChannelList() : _Conversation(key: ValueKey(selected), channelId: selected),
    );
  }
}

/// A chat's name: Everyone, or the other person.
String chatTitle(ChatChannel? c) => c == null || c.isPublic ? 'Everyone' : (c.person?.name ?? 'Private chat');

String _when(int unixSeconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) return DateFormat.jm().format(t);
  if (now.difference(t).inDays < 7) return DateFormat.E().format(t);
  return DateFormat.MMMd().format(t);
}

class _ChannelList extends StatelessWidget {
  const _ChannelList();

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<AppChat>();
    final friends = context.watch<FriendsLink>().presence.friends;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = chat.me;
    final withChat = {for (final c in chat.channels) ?c.person?.id};
    final others = friends.where((f) => !withChat.contains(f.person.id)).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (!chat.connected && chat.running)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
            child: Text(
              'Reconnecting… new messages show up once the Hub is back.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        for (final c in chat.channels) _ChannelTile(channel: c, me: me),
        if (others.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
            child: Text('Start a private chat', style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
          ),
          for (final f in others)
            ListTile(
              dense: true,
              leading: PersonAvatar(
                id: f.person.id,
                name: f.person.name,
                photo: f.person.photo,
                online: f.online,
                size: 34,
              ),
              title: VerifiedName(f.person.name, admin: f.person.admin),
              trailing: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
              onTap: () => chat.openWith(f.person),
            ),
        ],
      ],
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.me});

  final ChatChannel channel;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = channel.last;
    final preview = last == null
        ? (channel.isPublic ? 'Say hi to everyone' : 'No messages yet')
        : '${last.from.id == me ? 'You' : last.from.name.split(' ').first}: ${last.text.replaceAll('\n', ' ')}';
    final unread = channel.unread > 0;
    final person = channel.person;
    return ListTile(
      leading: channel.isPublic
          ? CircleAvatar(
              radius: 19,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.forum_rounded, size: 20, color: scheme.onPrimaryContainer),
            )
          : PersonAvatar(id: person?.id ?? channel.id, name: person?.name ?? '?', photo: person?.photo, size: 38),
      title: VerifiedName(
        chatTitle(channel),
        admin: person?.admin ?? false,
        style: TextStyle(fontWeight: unread ? FontWeight.w700 : FontWeight.w600),
      ),
      subtitle: Text(
        preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: unread ? scheme.onSurface : scheme.onSurfaceVariant,
          fontWeight: unread ? FontWeight.w600 : null,
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (last != null)
            Text(_when(last.sentAt), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          if (unread) ...[
            const SizedBox(height: 4),
            Badge(
              label: Text(channel.unread >= 100 ? '99+' : '${channel.unread}'),
              backgroundColor: scheme.primary,
              textColor: scheme.onPrimary,
            ),
          ],
        ],
      ),
      onTap: () => context.read<AppChat>().selected = channel.id,
    );
  }
}

/// One chat: its messages, newest at the bottom, and the composer.
class _Conversation extends StatefulWidget {
  const _Conversation({super.key, required this.channelId});

  final String channelId;

  @override
  State<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends State<_Conversation> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final AppChat _chat;
  bool _emoji = false;
  bool _sending = false;
  String? _error;

  /// What a moderation step did, shown where errors show.
  String? _note;

  @override
  void initState() {
    super.initState();
    _chat = context.read<AppChat>();
    // Marks it read and loads the latest page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chat.viewing = widget.channelId;
    });
    _scroll.addListener(_onScroll);
    _focus.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    // Not while the tree is being torn down: listeners would rebuild.
    final chat = _chat;
    final id = widget.channelId;
    scheduleMicrotask(() {
      if (chat.viewing == id) chat.viewing = null;
    });
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The list runs bottom-up, so its end is the oldest message.
  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
      final t = _chat.thread(widget.channelId);
      if (t.started && t.more && !t.loading) unawaited(_chat.loadOlder(widget.channelId).catchError((_) {}));
    }
  }

  /// Enter sends; Shift+Enter starts a new line.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_send());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Runs a moderation [action], showing what went wrong under the messages.
  Future<void> _moderate(Future<void> Function() action, {String? done}) async {
    setState(() {
      _error = null;
      _note = null;
    });
    try {
      await action();
      if (done != null && mounted) setState(() => _note = done);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  List<_Action> _actions(ChatMessage m) {
    final from = m.from;
    final first = from.name.split(' ').first;
    return [
      if (_chat.canDelete(m))
        _Action(Icons.delete_outline_rounded, 'Delete message', () => _moderate(() => _chat.delete(m))),
      if (_chat.canMute(from)) ...[
        _Action(
          Icons.volume_off_outlined,
          'Mute $first for 1 hour',
          () => _moderate(() => _chat.mute(from, minutes: 60), done: '$first is muted for an hour.'),
        ),
        _Action(
          Icons.volume_off_outlined,
          'Mute $first for 1 day',
          () => _moderate(() => _chat.mute(from, minutes: 24 * 60), done: '$first is muted for a day.'),
        ),
        _Action(
          Icons.block_rounded,
          'Ban $first from chat',
          () => _moderate(() => _chat.mute(from), done: '$first can\'t send messages until you lift it.'),
        ),
        _Action(
          Icons.volume_up_outlined,
          'Lift $first\'s mute',
          () => _moderate(() => _chat.mute(from, minutes: 0), done: '$first can write again.'),
        ),
      ],
    ];
  }

  Future<void> _send() async {
    final text = _text.text;
    if (_sending || chatText(text) == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _chat.send(widget.channelId, text);
      _text.clear();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } on HubException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _sending = false);
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<AppChat>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final channel = chat.channel(widget.channelId);
    final thread = chat.thread(widget.channelId);
    final messages = thread.messages;
    final me = chat.me;

    return Column(
      key: ValueKey(widget.channelId),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'All chats',
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                onPressed: () => chat.selected = null,
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: VerifiedName(
                    chatTitle(channel),
                    admin: channel?.person?.admin ?? false,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (!chat.connected && chat.running)
                Tooltip(
                  message: 'Reconnecting to the Hub',
                  child: Icon(Icons.cloud_off_rounded, size: 16, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: thread.loading || !thread.started
                      ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(
                          channel?.isPublic ?? true ? 'No messages yet. Say hi 👋' : 'Start your private chat 👋',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                )
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  itemCount: messages.length + (thread.more ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == messages.length) {
                      return const Padding(
                        padding: EdgeInsets.all(8),
                        child: Center(
                          child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      );
                    }
                    final index = messages.length - 1 - i;
                    final m = messages[index];
                    final before = index > 0 ? messages[index - 1] : null;
                    final after = index < messages.length - 1 ? messages[index + 1] : null;
                    return _MessageBubble(
                      message: m,
                      actions: _actions(m),
                      mine: m.from.id == me,
                      showName: (channel?.isPublic ?? true) && before?.from.id != m.from.id,
                      // Avatar and time on the last of a run from one person.
                      lastOfRun: after?.from.id != m.from.id || after!.sentAt - m.sentAt > 300,
                    );
                  },
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          )
        else if (_note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Text(_note!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
        if (chat.mutedUntil case final until?)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Icon(Icons.volume_off_rounded, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    mutedNotice(until),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: _emoji ? 'Hide emoji' : 'Emoji',
                  isSelected: _emoji,
                  icon: const Icon(Icons.emoji_emotions_outlined, size: 22),
                  selectedIcon: const Icon(Icons.emoji_emotions_rounded, size: 22),
                  onPressed: () => setState(() => _emoji = !_emoji),
                ),
                Expanded(
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: maxChatChars,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      isDense: true,
                      counterText: '',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _text,
                  builder: (context, value, _) => IconButton(
                    tooltip: 'Send',
                    icon: _sending
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded, size: 20),
                    color: scheme.primary,
                    onPressed: _sending || chatText(value.text) == null ? null : () => unawaited(_send()),
                  ),
                ),
              ],
            ),
          ),
        if (_emoji && chat.mutedUntil == null)
          EmojiPicker(
            textEditingController: _text,
            config: Config(
              height: 220,
              emojiViewConfig: EmojiViewConfig(
                columns: 8,
                emojiSizeMax: 24,
                backgroundColor: scheme.surfaceContainerHigh,
                noRecents: Text(
                  'Your recent emoji show here',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              categoryViewConfig: CategoryViewConfig(
                tabBarHeight: 38,
                backgroundColor: scheme.surfaceContainerHigh,
                indicatorColor: scheme.primary,
                iconColor: scheme.onSurfaceVariant,
                iconColorSelected: scheme.primary,
                backspaceColor: scheme.primary,
                dividerColor: scheme.outlineVariant,
              ),
              skinToneConfig: SkinToneConfig(
                dialogBackgroundColor: scheme.surfaceContainerHighest,
                indicatorColor: scheme.onSurfaceVariant,
              ),
              searchViewConfig: SearchViewConfig(
                backgroundColor: scheme.surfaceContainerHigh,
                buttonIconColor: scheme.onSurfaceVariant,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            ),
          ),
      ],
    );
  }
}

// The lint checks without the unicode flag, which \p{…} and \u{…} need; it matches at run time.
final _emojiOnly = RegExp(
  // ignore: valid_regexps
  r'^(?:\p{Extended_Pictographic}|[\u{1F3FB}-\u{1F3FF}\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{200D}])+$',
  unicode: true,
);

/// True for a message that's only emoji (up to three), shown larger.
bool onlyEmoji(String text) {
  final t = text.replaceAll(RegExp(r'\s'), '');
  return t.isNotEmpty && t.characters.length <= 3 && _emojiOnly.hasMatch(t);
}

/// What the composer says instead while this user is muted until [until].
String mutedNotice(int until) {
  if (until >= chatMutedForever) return 'A chat admin turned off sending messages for you. You can still read.';
  final t = DateTime.fromMillisecondsSinceEpoch(until * 1000);
  final now = DateTime.now();
  final today = t.year == now.year && t.month == now.month && t.day == now.day;
  final when = today ? DateFormat.jm().format(t) : DateFormat.MMMd().add_jm().format(t);
  return 'A chat admin muted you. You can write again at $when.';
}

/// Something this user may do to a message, from its menu.
class _Action {
  const _Action(this.icon, this.label, this.run);

  final IconData icon;
  final String label;
  final VoidCallback run;
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.message,
    required this.actions,
    required this.mine,
    required this.showName,
    required this.lastOfRun,
  });

  final ChatMessage message;
  final List<_Action> actions;
  final bool mine;
  final bool showName;
  final bool lastOfRun;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _hover = false;
  final _menu = MenuController();

  /// The message's menu button, shown while the pointer is over it (or the
  /// menu is open). A MenuAnchor needs only the bubble's own Overlay.
  Widget _menuButton(ColorScheme scheme) => MenuAnchor(
    controller: _menu,
    onClose: () => setState(() {}),
    menuChildren: [
      for (final a in widget.actions)
        MenuItemButton(leadingIcon: Icon(a.icon, size: 18), onPressed: a.run, child: Text(a.label)),
    ],
    builder: (context, controller, _) => AnimatedOpacity(
      opacity: _hover || controller.isOpen ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: IconButton(
        tooltip: 'More',
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: scheme.onSurfaceVariant,
        icon: const Icon(Icons.more_horiz_rounded),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final mine = widget.mine;
    final showName = widget.showName;
    final lastOfRun = widget.lastOfRun;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final big = onlyEmoji(message.text);
    final from = message.from;
    final bubble = Container(
      padding: big ? const EdgeInsets.symmetric(horizontal: 2) : const EdgeInsets.fromLTRB(11, 7, 11, 7),
      decoration: big
          ? null
          : BoxDecoration(
              color: mine ? scheme.primary : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft: Radius.circular(mine || !lastOfRun ? 14 : 4),
                bottomRight: Radius.circular(mine && lastOfRun ? 4 : 14),
              ),
            ),
      child: SelectableText(
        message.text,
        style: big
            ? const TextStyle(fontSize: 34, height: 1.15)
            : theme.textTheme.bodyMedium?.copyWith(color: mine ? scheme.onPrimary : scheme.onSurface),
      ),
    );
    final menu = widget.actions.isEmpty ? null : _menuButton(scheme);
    final row = Padding(
      padding: EdgeInsets.only(top: showName ? 8 : 1, bottom: lastOfRun ? 6 : 1),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (mine && menu != null) menu,
          if (!mine)
            SizedBox(
              width: 34,
              child: lastOfRun ? PersonAvatar(id: from.id, name: from.name, photo: from.photo, size: 28) : null,
            ),
          Flexible(
            child: Column(
              crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (showName && !mine)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 2),
                    child: VerifiedName(
                      from.name,
                      admin: from.admin,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary),
                    ),
                  ),
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 250), child: bubble),
                if (lastOfRun)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4, top: 2),
                    child: Text(
                      _when(message.sentAt),
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          if (!mine && menu != null) menu,
        ],
      ),
    );
    if (menu == null) return row;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // A long press opens the menu on touch screens.
      child: GestureDetector(onLongPress: _menu.open, child: row),
    );
  }
}
