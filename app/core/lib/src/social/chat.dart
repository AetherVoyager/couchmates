import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../hub/api.dart';
import '../hub/hub_client.dart';
import '../rules.dart';

/// The live chat socket, as [Chat] needs it.
abstract class ChatSocket {
  /// Text frames from the Hub. Done when the socket closes.
  Stream<String> get frames;
  void send(String text);
  Future<void> close();
}

/// Opens a [ChatSocket] at [url] with [headers].
typedef ChatConnector = Future<ChatSocket> Function(Uri url, Map<String, String> headers);

/// The real socket, over `dart:io`.
Future<ChatSocket> connectChatSocket(Uri url, Map<String, String> headers) async =>
    _IoChatSocket(await WebSocket.connect(url.toString(), headers: headers).timeout(const Duration(seconds: 20)));

class _IoChatSocket implements ChatSocket {
  _IoChatSocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<String> get frames => _ws.where((f) => f is String).cast<String>();

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close() => _ws.close();
}

/// One channel's messages loaded so far, oldest first.
class ChatThread {
  final List<ChatMessage> messages = [];

  /// There are older messages on the Hub than [messages].
  bool more = true;
  bool loading = false;

  /// The latest page has been loaded; new messages are added from then on.
  bool started = false;

  int? get newest => messages.isEmpty ? null : messages.last.id;

  /// Adds [m] in order, unless it's already here.
  bool add(ChatMessage m) {
    if (messages.isNotEmpty && m.id > messages.last.id) {
      messages.add(m);
      return true;
    }
    if (messages.any((x) => x.id == m.id)) return false;
    messages.add(m);
    messages.sort((a, b) => a.id.compareTo(b.id));
    return true;
  }
}

/// The Hub's chat: the public channel and private chats, kept for good on
/// the Hub. While [start]ed, holds a socket that brings new messages as they
/// are sent, and reconnects (catching up on what it missed) when it drops.
class Chat extends ChangeNotifier {
  Chat({
    required HubClient? Function() hub,
    required String? Function() me,
    ChatConnector connect = connectChatSocket,
    this.pingEvery = const Duration(seconds: 30),
  }) : _hub = hub,
       _me = me,
       _connect = connect;

  final HubClient? Function() _hub;
  final String? Function() _me;
  final ChatConnector _connect;
  final Duration pingEvery;

  List<ChatChannel> _channels = const [ChatChannel(id: publicChannel, unread: 0)];
  final Map<String, ChatThread> _threads = {};
  final _incoming = StreamController<ChatMessage>.broadcast();
  bool _loaded = false;
  bool _connected = false;
  String? _viewing;

  /// The public channel first, then private chats, latest first.
  List<ChatChannel> get channels => _channels;
  bool get loaded => _loaded;

  /// The live socket is up: new messages arrive as they're sent.
  bool get connected => _connected;

  /// Unread messages over all channels.
  int get unread => _channels.fold(0, (n, c) => n + c.unread);

  /// Each new message from someone else, as it arrives.
  Stream<ChatMessage> get incoming => _incoming.stream;

  ChatChannel? channel(String id) => _channels.where((c) => c.id == id).firstOrNull;

  /// [id]'s messages loaded so far; empty until [view] loads them.
  ChatThread thread(String id) => _threads.putIfAbsent(id, ChatThread.new);

  /// The private chat with [person], listed (empty) if it's new.
  String directWith(Person person) {
    final me = _me();
    if (me == null) throw const HubException('Sign in first.');
    final id = directChannel(me, person.id);
    if (channel(id) == null) {
      _channels = [..._channels, ChatChannel(id: id, person: person, unread: 0)];
      notifyListeners();
    }
    return id;
  }

  /// The channel on screen (null: none). Messages arriving in it count as
  /// read; opening one loads its latest page and marks it read.
  String? get viewing => _viewing;
  set viewing(String? id) {
    if (id == _viewing) return;
    _viewing = id;
    if (id != null) {
      unawaited(_openThread(id));
      _markRead(id);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Connection

  bool _running = false;
  ChatSocket? _socket;
  StreamSubscription<String>? _frames;
  Timer? _ping;
  Timer? _retry;
  int _failures = 0;
  int _generation = 0;

  bool get running => _running;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(refresh());
    unawaited(_open());
  }

  Future<void> stop() async {
    _running = false;
    _generation++;
    _retry?.cancel();
    _retry = null;
    await _drop();
  }

  Future<void> _drop() async {
    _ping?.cancel();
    _ping = null;
    await _frames?.cancel();
    _frames = null;
    final socket = _socket;
    _socket = null;
    if (_connected) {
      _connected = false;
      if (!_disposed) notifyListeners();
    }
    await socket?.close();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    final hub = _hub();
    if (hub == null || !_running) return;
    try {
      final socket = await _connect(hub.chatLiveUrl, hub.authHeaders);
      if (generation != _generation || !_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _frames = socket.frames.listen(_onFrame, onDone: () => _onLost(generation), onError: (_) => _onLost(generation));
      _ping = Timer.periodic(pingEvery, (_) => _send('ping'));
      _connected = true;
      _failures = 0;
      notifyListeners();
      // Whatever was sent while the socket was down.
      await refresh();
      await _catchUp();
    } catch (_) {
      if (generation != _generation) return;
      _scheduleRetry();
      // Without the socket, the list still updates at each retry.
      if (_failures > 1) {
        await refresh();
        await _catchUp();
      }
    }
  }

  void _send(String text) {
    try {
      _socket?.send(text);
    } catch (_) {}
  }

  void _onLost(int generation) {
    if (generation != _generation) return;
    unawaited(_drop());
    _scheduleRetry();
  }

  /// 2, 4, 8 … seconds, at most a minute.
  void _scheduleRetry() {
    if (!_running) return;
    _failures++;
    final seconds = (1 << _failures.clamp(1, 6)).clamp(2, 60);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), () => unawaited(_open()));
  }

  void _onFrame(String frame) {
    if (frame == 'pong') return;
    try {
      final event = ChatEvent.fromJson(jsonDecode(frame) as Json);
      if (event.kind == 'message' && event.message != null) receive(event.message!);
    } catch (_) {
      // A frame this version doesn't understand.
    }
  }

  // ---------------------------------------------------------------------------
  // Messages

  /// Lists the channels and unread counts again. Never throws.
  Future<void> refresh() async {
    final hub = _hub();
    if (hub == null) return;
    try {
      final overview = await hub.chatChannels();
      final listed = {for (final c in overview.channels) c.id};
      // Keep private chats started here that have no messages yet.
      final started = _channels.where((c) => !listed.contains(c.id) && c.last == null && !c.isPublic);
      _channels = [for (final c in overview.channels) c.id == _viewing ? c.copyWith(unread: 0) : c, ...started];
      _loaded = true;
      notifyListeners();
      if (_viewing != null) _markRead(_viewing!);
    } on HubException {
      // Shown as not connected; the next connect tries again.
    }
  }

  /// Fetches what's newer than the loaded messages of every open thread.
  Future<void> _catchUp() async {
    final hub = _hub();
    if (hub == null) return;
    for (final MapEntry(key: id, value: t) in _threads.entries.toList()) {
      final after = t.newest;
      if (!t.started || after == null) continue;
      try {
        var page = await hub.chatMessages(id, after: after);
        while (true) {
          page.messages.forEach(receive);
          if (!page.more || page.messages.isEmpty) break;
          page = await hub.chatMessages(id, after: page.messages.last.id);
        }
      } on HubException {
        continue;
      }
    }
    notifyListeners();
  }

  Future<void> _openThread(String id) async {
    final t = thread(id);
    if (t.started || t.loading) return;
    await loadOlder(id);
  }

  /// Loads the page before the oldest loaded message of [id] (or the
  /// latest page). Throws [HubException].
  Future<void> loadOlder(String id) async {
    final hub = _hub();
    final t = thread(id);
    if (hub == null || t.loading || !t.more) return;
    t.loading = true;
    notifyListeners();
    try {
      final page = await hub.chatMessages(id, before: t.messages.isEmpty ? null : t.messages.first.id);
      page.messages.forEach(t.add);
      page.messages.forEach((m) => _seen.add(m.id));
      t.more = page.more;
      t.started = true;
    } finally {
      t.loading = false;
      notifyListeners();
    }
    if (id == _viewing) _markRead(id);
  }

  /// Sends [text] to channel [id]. Throws [HubException].
  Future<ChatMessage> send(String id, String text) async {
    final hub = _hub();
    if (hub == null) throw const HubException('Sign in first.');
    final clean = chatText(text);
    if (clean == null) throw const HubException('Write something first (at most 2000 characters).');
    final message = await hub.sendChat(id, clean);
    receive(message);
    return message;
  }

  /// Takes in a message from the socket or from sending one. Each counts once.
  void receive(ChatMessage m) {
    final t = _threads[m.channel];
    if (t != null && t.started) t.add(m);
    if (!_seen.add(m.id) || (channel(m.channel)?.last?.id ?? 0) >= m.id) {
      notifyListeners();
      return;
    }
    final mine = m.from.id == _me();
    final known = channel(m.channel);
    final counts = !mine && m.channel != _viewing;
    if (known == null) {
      // A new private chat. From someone else, they're the other person;
      // from this user's other device, the Hub knows who it's with.
      if (mine) unawaited(refresh());
      _channels = [
        ..._channels,
        ChatChannel(id: m.channel, person: mine ? null : m.from, last: m, unread: counts ? 1 : 0),
      ];
    } else {
      final newer = (known.last?.id ?? 0) < m.id;
      final updated = known.copyWith(last: newer ? m : null, unread: known.unread + (counts ? 1 : 0));
      _channels = [for (final c in _channels) c.id == m.channel ? updated : c];
    }
    _sort();
    if (!mine) _incoming.add(m);
    if (m.channel == _viewing) _markRead(m.channel);
    notifyListeners();
  }

  /// Public first, then private chats by their latest message.
  void _sort() {
    final public = _channels.where((c) => c.isPublic);
    final direct = _channels.where((c) => !c.isPublic).toList()
      ..sort((a, b) => (b.last?.id ?? 1 << 52).compareTo(a.last?.id ?? 1 << 52));
    _channels = [...public, ...direct];
  }

  final Map<String, int> _marked = {};
  final Set<int> _seen = {};

  void _markRead(String id) {
    final newest = _threads[id]?.newest ?? channel(id)?.last?.id;
    final c = channel(id);
    if (c != null && c.unread > 0) {
      _channels = [for (final x in _channels) x.id == id ? x.copyWith(unread: 0) : x];
      notifyListeners();
    }
    if (newest == null || (_marked[id] ?? 0) >= newest) return;
    _marked[id] = newest;
    final hub = _hub();
    if (hub == null) return;
    unawaited(hub.markChatRead(id, newest).catchError((_) {}));
  }

  /// Forgets everything, such as after signing out.
  void clear() {
    _channels = const [ChatChannel(id: publicChannel, unread: 0)];
    _threads.clear();
    _marked.clear();
    _seen.clear();
    _loaded = false;
    _viewing = null;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    // stop() finishes after this returns, so it mustn't notify then.
    _disposed = true;
    unawaited(stop());
    _incoming.close();
    super.dispose();
  }
}
