import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';

import '../screens/details_screen.dart';
import '../widgets/toasts.dart';

/// [RequestUpdates] with a notice for each of the user's requests that reaches the library, offering to open it.
RequestUpdates requestUpdatesWithNotices({
  required HubSession session,
  required AppSettings settings,
  required GlobalKey<NavigatorState> navigator,
}) {
  final updates = RequestUpdates(session: session, settings: settings);
  updates.arrivals.listen((r) {
    final meta = StremioMeta(id: r.titleId, type: r.kind, name: r.name, poster: r.poster, releaseInfo: r.year);
    toasts.show(
      '${r.label} is in the library now. You asked for it.',
      tone: ToastTone.success,
      action: 'Watch',
      onAction: () => navigator.currentState?.push(MaterialPageRoute<void>(builder: (_) => DetailsScreen(item: meta))),
    );
  });
  return updates;
}
