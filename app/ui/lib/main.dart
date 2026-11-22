import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'services/device_name.dart';
import 'services/prefs_session_store.dart';
import 'services/prefs_settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = PrefsSettingsStore();
  final settings = AppSettings(store);
  final progress = ProgressStore(store);
  final watchlist = Watchlist(store);
  await Future.wait([settings.load(), progress.load(), watchlist.load()]);
  final session = HubSession(store: PrefsSessionStore(), deviceName: await deviceName());
  runApp(CouchmatesApp(session: session, settings: settings, progress: progress, watchlist: watchlist));
  await session.restore();
}
