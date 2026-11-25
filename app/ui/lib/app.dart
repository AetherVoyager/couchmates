import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'chat/app_chat.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'services/request_alerts.dart';
import 'services/updater.dart';
import 'theme.dart';
import 'watch_together/friends.dart';
import 'watch_together/friends_bubble.dart';
import 'watch_together/watch_together.dart';
import 'widgets/toasts.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class CouchmatesApp extends StatelessWidget {
  const CouchmatesApp({
    super.key,
    required this.session,
    required this.settings,
    required this.progress,
    required this.watchlist,
    this.chatConnector,
  });

  final HubSession session;
  final AppSettings settings;
  final ProgressStore progress;
  final Watchlist watchlist;

  /// Opens the live chat socket; tests pass one that never reaches the network.
  final ChatConnector? chatConnector;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: progress),
        ChangeNotifierProvider.value(value: watchlist),
        ChangeNotifierProvider(
          create: (_) => Updater(session: session, settings: settings),
        ),
        ChangeNotifierProvider(
          create: (_) => WatchTogether(session: session, navigator: navigatorKey, settings: settings),
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (_) => requestUpdatesWithNotices(session: session, settings: settings, navigator: navigatorKey),
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (_) => AppChat(session: session, connect: chatConnector),
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (context) => FriendsLink(session: session, settings: settings, watch: context.read<WatchTogether>()),
        ),
      ],
      child: Consumer<AppSettings>(
        builder: (context, settings, _) {
          final themes = themesFor(settings);
          return MaterialApp(
            title: 'Couchmates',
            navigatorKey: navigatorKey,
            builder: (context, child) => ToastHost(child: FriendsBubble(child: child ?? const SizedBox.shrink())),
            debugShowCheckedModeBanner: false,
            theme: themes.light,
            darkTheme: themes.dark,
            themeMode: themes.mode,
            home: const _Root(),
          );
        },
      ),
    );
  }
}

/// Sign-in or home, following the session.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final status = context.select<HubSession, SessionStatus>((s) => s.status);
    return switch (status) {
      SessionStatus.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      SessionStatus.signedOut => const SignInScreen(),
      SessionStatus.signedIn => const HomeScreen(),
    };
  }
}
