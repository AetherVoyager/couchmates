import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String sample(String name) => File('../../core/contract/$name').readAsStringSync();

class FakeSocket implements ChatSocket {
  final controller = StreamController<String>();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get frames => controller.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }

  void push(ChatMessage m) => controller.add(jsonEncode(ChatEvent(kind: 'message', message: m).toJson()));
}

const me = '5555666677778888';
const bob = Person(id: '1111222233334444', name: 'Bob');
const carol = Person(id: '9999000011112222', name: 'Carol');

ChatMessage msg(int id, {String channel = publicChannel, Person from = bob, String text = 'hi'}) =>
    ChatMessage(id: id, channel: channel, from: from, text: text, sentAt: 1795280000 + id);

void main() {
  late List<http.Request> sent;
  late List<FakeSocket> sockets;
  late Map<String, Object> replies;

  Chat make() {
    sent = [];
    sockets = [];
    replies = {
      HubPaths.chat: sample('chat_overview.json'),
      HubPaths.chatMessages: sample('chat_messages.json'),
      HubPaths.chatRead: '{"ok": true}',
    };
    final hub = HubClient(
      baseUrl: Uri.parse('https://hub.example.com'),
      token: 't',
      httpClient: MockClient((request) async {
        sent.add(request);
        if (request.url.path == HubPaths.chatSend) {
          final body = ChatSend.fromJson(jsonDecode(request.body) as Json);
          final me_ = Person(id: me, name: 'Me');
          return http.Response.bytes(
            utf8.encode(jsonEncode(msg(500, channel: body.channel, from: me_, text: body.text).toJson())),
            200,
          );
        }
        return http.Response.bytes(utf8.encode(replies[request.url.path] as String), 200);
      }),
    );
    return Chat(
      hub: () => hub,
      me: () => me,
      connect: (url, headers) async {
        expect(url.toString(), 'wss://hub.example.com/api/app/chat/live');
        expect(headers['authorization'], 'Bearer t');
        final s = FakeSocket();
        sockets.add(s);
        return s;
      },
    );
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero).then((_) => Future<void>.delayed(Duration.zero));

  test('connects, lists the channels and their unread counts', () async {
    final chat = make();
    chat.start();
    await settle();
    expect(chat.connected, isTrue);
    expect(chat.channels.map((c) => c.id), ['public', 'dm:1111222233334444:5555666677778888']);
    expect(chat.unread, 3);
    await chat.stop();
    expect(sockets.single.closed, isTrue);
  });

  test('a live message counts as unread once, unless its channel is open', () async {
    final chat = make();
    chat.start();
    await settle();
    final arrived = <String>[];
    chat.incoming.listen((m) => arrived.add(m.text));
    sockets.single.push(msg(200, text: 'yo'));
    sockets.single.push(msg(200, text: 'yo'));
    await settle();
    expect(chat.channel('public')!.unread, 4);
    expect(chat.channel('public')!.last!.text, 'yo');
    expect(arrived, ['yo']);

    // The Hub's latest page now ends with it.
    replies[HubPaths.chatMessages] = jsonEncode(
      ChatMessages(
        messages: [
          msg(120),
          msg(121),
          msg(200, text: 'yo'),
        ],
        more: true,
      ).toJson(),
    );
    chat.viewing = 'public';
    await settle();
    expect(chat.channel('public')!.unread, 0);
    expect(sent.where((r) => r.url.path == HubPaths.chatRead).map((r) => jsonDecode(r.body)['up_to']), [200]);
    sockets.single.push(msg(201));
    await settle();
    expect(chat.channel('public')!.unread, 0);
    expect(chat.thread('public').messages.map((m) => m.id), [120, 121, 200, 201]);
  });

  test('a message from someone new starts a private chat', () async {
    final chat = make();
    chat.start();
    await settle();
    sockets.single.push(msg(300, channel: directChannel(me, carol.id), from: carol, text: 'psst'));
    await settle();
    final c = chat.channel(directChannel(me, carol.id))!;
    expect(c.person!.name, 'Carol');
    expect(c.unread, 1);
    // Newest private chat first, after the public channel.
    expect(chat.channels[1].id, c.id);
  });

  test('sending adds the message without counting it', () async {
    final chat = make();
    final id = chat.directWith(carol);
    expect(id, 'dm:5555666677778888:9999000011112222');
    final m = await chat.send(id, '  on my way 🏃 ');
    expect(jsonDecode(sent.last.body), {'channel': id, 'text': 'on my way 🏃'});
    expect(m.text, 'on my way 🏃');
    expect(chat.channel(id)!.unread, 0);
    expect(chat.channel(id)!.last!.id, 500);
    expect(() => chat.send(id, '   '), throwsA(isA<HubException>()));
  });

  test('reconnects after the socket drops and catches up', () async {
    final chat = make();
    chat.start();
    await settle();
    chat.viewing = 'public';
    await settle();
    replies[HubPaths.chatMessages] = jsonEncode(ChatMessages(messages: [msg(130)], more: false).toJson());
    await sockets.single.controller.close();
    await settle();
    expect(chat.connected, isFalse);
    // The first retry waits two seconds.
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    await settle();
    expect(sockets, hasLength(2));
    expect(chat.connected, isTrue);
    final after = sent.lastWhere((r) => r.url.path == HubPaths.chatMessages).url.queryParameters['after'];
    expect(after, '121');
    expect(chat.thread('public').messages.last.id, 130);
    await chat.stop();
  });

  test('pings to keep the socket open', () async {
    final chat = Chat(
      hub: () => HubClient(
        baseUrl: Uri.parse('http://localhost:8787'),
        token: 't',
        httpClient: MockClient((r) async {
          return http.Response(sample('chat_overview.json'), 200);
        }),
      ),
      me: () => me,
      pingEvery: const Duration(milliseconds: 20),
      connect: (url, _) async {
        expect(url.scheme, 'ws');
        final s = FakeSocket();
        sockets = [s];
        return s;
      },
    );
    chat.start();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(sockets.single.sent, contains('ping'));
    await chat.stop();
  });
}
