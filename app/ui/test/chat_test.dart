import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:couchmates/app.dart';
import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

String contract(String name) => File('../../core/contract/$name').readAsStringSync();

http.Response json(String body) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json'});

/// Signs in to a fake Hub that has chats, and returns what the app sent.
Future<List<http.Request>> signIn(WidgetTester tester) async {
  final sent = <http.Request>[];
  final session = HubSession(
    store: MemorySessionStore(),
    deviceName: 'Test PC',
    httpClient: () => MockClient((request) async {
      sent.add(request);
      if (request.url.host != 'hub.example.com') return http.Response('not found', 404);
      return switch (request.url.path) {
        HubPaths.login => json(contract('login_response.json')),
        HubPaths.config => json(contract('config_response.json')),
        // Friends, but no requests to join (those start a watch party).
        HubPaths.presence => json(jsonEncode({...jsonDecode(contract('activity.json')) as Json, 'requests': []})),
        HubPaths.chat => json(contract('chat_overview.json')),
        HubPaths.chatMessages => json(contract('chat_messages.json')),
        HubPaths.chatRead => json('{"ok": true}'),
        HubPaths.chatSend => json(
          jsonEncode({
            ...jsonDecode(contract('chat_message.json')) as Json,
            'id': 900,
            'text': (jsonDecode(request.body) as Json)['text'],
          }),
        ),
        _ => http.Response('{"error":"Not found"}', 404),
      };
    }),
  );
  await tester.pumpWidget(
    CouchmatesApp(
      session: session,
      settings: AppSettings(MemorySettingsStore()),
      progress: ProgressStore(MemorySettingsStore()),
      watchlist: Watchlist(MemorySettingsStore()),
      chatConnector: noSocket,
    ),
  );
  await tester.runAsync(session.restore);
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextFormField, 'Hub address'), 'hub.example.com');
  await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'alice');
  await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'correct horse');
  await tester.runAsync(() async {
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    for (var i = 0; i < 20 && session.status != SessionStatus.signedIn; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump(const Duration(seconds: 1));
  return sent;
}

/// Lets real-time work (the fake Hub's answers) finish, then draws.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A chat message on screen (they're selectable).
Finder message(String text) => find.byWidgetPredicate((w) => w is SelectableText && w.data == text);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Couchmates',
      packageName: 'couchmates',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('the bubble has a chat: list, conversation and sending', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = await signIn(tester);

    await tester.tap(find.byIcon(Icons.live_tv_rounded));
    await settle(tester);
    expect(find.text('Watching'), findsOneWidget);
    await tester.tap(find.text('Chat'));
    await settle(tester);

    // Everyone first, then the private chat with Carol, with unread counts.
    expect(find.text('Everyone'), findsOneWidget);
    expect(find.text('Carol'), findsWidgets);
    expect(find.textContaining('Starting Inception'), findsOneWidget);

    await tester.tap(find.text('Everyone'));
    await settle(tester);
    expect(message('anyone up for a movie?'), findsOneWidget);
    final read = sent.where((r) => r.url.path == HubPaths.chatRead).map((r) => jsonDecode(r.body) as Json);
    expect(read.last, {'channel': 'public', 'up_to': 121});

    await tester.enterText(find.widgetWithText(TextField, 'Message'), 'see you there 🍿');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    final send = sent.lastWhere((r) => r.url.path == HubPaths.chatSend);
    expect(jsonDecode(send.body), {'channel': 'public', 'text': 'see you there 🍿'});
    expect(message('see you there 🍿'), findsOneWidget);

    // The emoji picker opens under the composer.
    await tester.tap(find.byTooltip('Emoji'));
    await settle(tester);
    expect(find.byTooltip('Hide emoji'), findsOneWidget);

    await tester.tap(find.byTooltip('All chats'));
    await settle(tester);
    expect(find.text('Everyone'), findsOneWidget);

    // Close the app and let its timers (retries, tooltips) run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
  });
}

/// The live chat socket in tests: connects at once and stays quiet, so no real WebSocket is opened and nothing
/// is left running when a test ends.
Future<ChatSocket> noSocket(Uri url, Map<String, String> headers) async => _QuietSocket();

class _QuietSocket implements ChatSocket {
  final _frames = StreamController<String>();

  @override
  Stream<String> get frames => _frames.stream;

  @override
  void send(String text) {}

  @override
  Future<void> close() => _frames.close();
}
