import 'package:couchmates/widgets/toasts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A frame to start the animations, then long enough for them to finish.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  Widget host(Toasts t) => MaterialApp(
    builder: (context, child) => ToastHost(controller: t, child: child!),
    home: const Scaffold(body: SizedBox.expand()),
  );

  testWidgets('a toast shows top right and fades out after 15 seconds', (tester) async {
    final t = Toasts();
    await tester.pumpWidget(host(t));
    t.show('Room code copied');
    await settle(tester);
    expect(find.text('Room code copied'), findsOneWidget);
    final box = tester.getRect(find.text('Room code copied'));
    final screen = tester.getSize(find.byType(MaterialApp));
    expect(box.center.dx, greaterThan(screen.width / 2));
    expect(box.top, lessThan(80));

    await tester.pump(const Duration(seconds: 14));
    expect(find.text('Room code copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('Room code copied'), findsNothing);
    expect(t.shown, isEmpty);
  });

  testWidgets('the close button and the action close it at once', (tester) async {
    final t = Toasts();
    var watched = false;
    await tester.pumpWidget(host(t));
    t.show('Dune is in the library now.', action: 'Watch', onAction: () => watched = true);
    t.show('Requested Dune.');
    await settle(tester);

    await tester.tap(find.text('Watch'));
    await settle(tester);
    expect(watched, isTrue);
    expect(find.text('Dune is in the library now.'), findsNothing);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);
    expect(t.shown, isEmpty);
  });

  test('a tag replaces the earlier toast and only a few show at once', () {
    final t = Toasts();
    t.show('Resumed at 4:00', tag: 'player');
    t.show('Subtitles off', tag: 'player');
    expect(t.shown.map((x) => x.text), ['Subtitles off']);
    for (var i = 0; i < 6; i++) {
      t.show('n$i');
    }
    expect(t.shown, hasLength(Toasts.maxShown));
    expect(t.shown.last.text, 'n5');
  });
}
