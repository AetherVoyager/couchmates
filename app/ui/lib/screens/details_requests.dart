import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme.dart';
import '../widgets/poster.dart';
import 'search_screen.dart';
import '../widgets/toasts.dart';

/// Opens [item]: the library's details when it has the title, otherwise another catalog's, marked as not in
/// the library so it can be requested.
Future<TitleLookup> openTitle(HubSession session, StremioMeta item) async {
  final search = session.titleSearch;
  final catalog = session.catalog;
  if (search == null) {
    final meta = await catalog?.meta(item.type, item.id);
    return TitleLookup(meta: meta ?? item, inLibrary: true);
  }
  final found = await search.lookUp(item);
  if (found.inLibrary) return found;
  // A public add-on that streams it makes it watchable anyway.
  if (catalog is AddonSet && await catalog.streamsElsewhere(item.type, item.id).catchError((Object _) => false)) {
    final meta = await catalog.meta(item.type, item.id).catchError((Object _) => null);
    return TitleLookup(meta: meta ?? found.meta, inLibrary: false, full: found.full, playable: true);
  }
  return found;
}

/// The episodes of [episodes] this user could still ask for: nobody asked, someone else did, or it was declined.
List<StremioVideo> askable(HubSession session, StremioMeta meta, Iterable<StremioVideo> episodes) => [
  for (final v in episodes)
    if (_askable(session.requestOfEpisode(meta, v))) v,
];

bool _askable(MediaRequest? r) => r == null || r.status == RequestStatus.declined || (!r.mine && r.open);

/// Asks for [episodes] of [meta] and says how it went.
Future<void> askForEpisodes(BuildContext context, StremioMeta meta, List<StremioVideo> episodes) async {
  try {
    final saved = await context.read<HubSession>().askForEpisodes(meta, episodes);
    final n = saved.length;
    toasts.success(
      n == 1
          ? 'Requested ${saved.first.label}. You\'ll see when the admin answers.'
          : 'Requested $n episodes of ${meta.name}. You\'ll see when the admin answers.',
    );
  } catch (e) {
    toasts.error(errorText(e));
  }
}

/// The main action for a title that isn't in the library: request it, join the request, withdraw, or its status.
/// For a show it asks for every episode that has come out and isn't asked for yet.
class RequestTitleActions extends StatefulWidget {
  const RequestTitleActions({super.key, required this.lookup});

  final TitleLookup lookup;

  @override
  State<RequestTitleActions> createState() => _RequestTitleActionsState();
}

class _RequestTitleActionsState extends State<RequestTitleActions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final meta = widget.lookup.meta;
    final theme = Theme.of(context);
    final note = Text(
      'Not in the library yet. A request goes to the admin.',
      style: theme.textTheme.bodyMedium?.copyWith(color: Cinema.muted),
    );
    final episodes = (widget.lookup.full?.videos ?? const <StremioVideo>[])
        .where((v) => isRequestableEpisode(v))
        .toList();
    if (meta.isSeries && episodes.isNotEmpty) {
      final left = askable(session, meta, episodes);
      final asked = episodes.length - left.length;
      return Wrap(
        spacing: 16,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _BigButton(
            icon: Icons.playlist_add_rounded,
            label: left.isEmpty
                ? 'Every episode is requested'
                : left.length == episodes.length
                ? 'Request all ${left.length} episodes'
                : 'Request the other ${left.length} episodes',
            onPressed: _busy || left.isEmpty ? null : () => _run(() => askForEpisodes(context, meta, left)),
          ),
          if (asked > 0)
            Text(
              '$asked of ${episodes.length} requested',
              style: theme.textTheme.bodyMedium?.copyWith(color: Cinema.muted),
            ),
          note,
          Text('Or pick episodes below.', style: theme.textTheme.bodyMedium?.copyWith(color: Cinema.faint)),
        ],
      );
    }
    final request = session.requestOf(meta);
    Widget action;
    if (request == null || (!request.mine && request.status != RequestStatus.added)) {
      action = _BigButton(
        icon: Icons.add_rounded,
        label: request == null ? 'Request' : 'I want it too',
        onPressed: _busy ? null : () => _run(() => askForTitle(context, meta)),
      );
    } else if (request.mine && request.open) {
      action = OutlinedButton(
        onPressed: _busy ? null : () => _run(() => _withdraw(context, request)),
        child: const Text('Withdraw my request'),
      );
    } else {
      action = const SizedBox.shrink();
    }
    return Wrap(
      spacing: 16,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        action,
        if (request != null) RequestStatusChip(request: request),
        if (request?.note != null) Text('Admin: ${request!.note}', style: theme.textTheme.bodyMedium),
        note,
      ],
    );
  }
}

/// The one-button version of [RequestTitleActions], for over artwork (the home page's featured titles): Request
/// (or I want it too, or every aired episode of a show), withdraw, or the request's status.
class RequestTitleButton extends StatefulWidget {
  const RequestTitleButton({super.key, required this.lookup});

  final TitleLookup lookup;

  @override
  State<RequestTitleButton> createState() => _RequestTitleButtonState();
}

class _RequestTitleButtonState extends State<RequestTitleButton> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final meta = widget.lookup.meta;
    final episodes = (widget.lookup.full?.videos ?? const <StremioVideo>[])
        .where((v) => isRequestableEpisode(v))
        .toList();
    if (meta.isSeries && episodes.isNotEmpty) {
      final left = askable(session, meta, episodes);
      return _BigButton(
        icon: left.isEmpty ? Icons.check_rounded : Icons.playlist_add_rounded,
        label: left.isEmpty
            ? 'Requested'
            : left.length == episodes.length
            ? 'Request'
            : 'Request the other ${left.length} episodes',
        onPressed: _busy || left.isEmpty ? null : () => _run(() => askForEpisodes(context, meta, left)),
      );
    }
    final request = session.requestOf(meta);
    if (request == null || (!request.mine && request.status != RequestStatus.added)) {
      return _BigButton(
        icon: Icons.add_rounded,
        label: request == null ? 'Request' : 'I want it too',
        onPressed: _busy ? null : () => _run(() => askForTitle(context, meta)),
      );
    }
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (request.mine && request.open)
          _BigButton(
            icon: Icons.close_rounded,
            label: 'Withdraw request',
            onPressed: _busy ? null : () => _run(() => _withdraw(context, request)),
          ),
        RequestStatusChip(request: request),
      ],
    );
  }
}

Future<void> _withdraw(BuildContext context, MediaRequest request) async {
  try {
    await context.read<HubSession>().withdrawRequest(request.id);
  } catch (e) {
    toasts.error(errorText(e));
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 26),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: Cinema.background,
      minimumSize: const Size(0, 50),
      padding: const EdgeInsets.fromLTRB(18, 0, 26, 0),
      textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

/// One episode's request: its status, or a button to ask for it (or join, or ask again after a decline).
class EpisodeRequestButton extends StatefulWidget {
  const EpisodeRequestButton({super.key, required this.meta, required this.video});

  final StremioMeta meta;
  final StremioVideo video;

  @override
  State<EpisodeRequestButton> createState() => _EpisodeRequestButtonState();
}

class _EpisodeRequestButtonState extends State<EpisodeRequestButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final v = widget.video;
    if (!isRequestableEpisode(v)) {
      return Text('Not out yet', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Cinema.faint));
    }
    final request = session.requestOfEpisode(widget.meta, v);
    final chip = request == null ? null : RequestStatusChip(request: request);
    if (!_askable(request)) return chip!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?chip,
        if (chip != null) const SizedBox(width: 8),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  await askForTitle(context, widget.meta, video: v);
                  if (mounted) setState(() => _busy = false);
                },
          icon: _busy
              ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add, size: 18),
          label: Text(
            request == null ? 'Request' : (request.status == RequestStatus.declined ? 'Ask again' : 'Me too'),
          ),
        ),
      ],
    );
  }
}

/// For a show in the library: the episodes that have come out but the library doesn't have, to ask for them
/// one by one or all at once.
class MissingEpisodes extends StatefulWidget {
  const MissingEpisodes({super.key, required this.meta, required this.missing});

  final StremioMeta meta;
  final List<StremioVideo> missing;

  @override
  State<MissingEpisodes> createState() => _MissingEpisodesState();
}

class _MissingEpisodesState extends State<MissingEpisodes> {
  bool _busy = false;
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    final missing = widget.missing;
    final left = askable(session, widget.meta, missing);
    final shown = _open || missing.length <= 6 ? missing : missing.take(6).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                missing.length == 1 ? '1 episode missing' : '${missing.length} episodes missing',
                style: theme.textTheme.headlineSmall,
              ),
              FilledButton.tonalIcon(
                onPressed: _busy || left.isEmpty
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        await askForEpisodes(context, widget.meta, left);
                        if (mounted) setState(() => _busy = false);
                      },
                icon: _busy
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.playlist_add_rounded),
                label: Text(
                  left.isEmpty
                      ? 'All requested'
                      : left.length == missing.length
                      ? 'Request all missing'
                      : 'Request the other ${left.length}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Out already, but not in the library.',
            style: theme.textTheme.bodyMedium?.copyWith(color: Cinema.muted),
          ),
          const SizedBox(height: 8),
          for (final v in shown)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A))),
              ),
              child: Row(
                children: [
                  SizedBox(width: 84, child: Text('S${v.season} E${v.episode}', style: theme.textTheme.titleSmall)),
                  Expanded(
                    child: Text(
                      v.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: Cinema.muted),
                    ),
                  ),
                  EpisodeRequestButton(meta: widget.meta, video: v),
                ],
              ),
            ),
          if (shown.length < missing.length)
            TextButton(onPressed: () => setState(() => _open = true), child: Text('Show all ${missing.length}')),
        ],
      ),
    );
  }
}

/// Asks for the episodes of one season that have come out and aren't asked for yet.
class RequestSeasonButton extends StatefulWidget {
  const RequestSeasonButton({super.key, required this.meta, required this.episodes});

  final StremioMeta meta;
  final List<StremioVideo> episodes;

  @override
  State<RequestSeasonButton> createState() => _RequestSeasonButtonState();
}

class _RequestSeasonButtonState extends State<RequestSeasonButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final left = askable(session, widget.meta, widget.episodes.where((v) => isRequestableEpisode(v)));
    if (left.isEmpty) return const SizedBox.shrink();
    return TextButton.icon(
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              await askForEpisodes(context, widget.meta, left);
              if (mounted) setState(() => _busy = false);
            },
      style: TextButton.styleFrom(foregroundColor: Cinema.muted),
      icon: const Icon(Icons.playlist_add_rounded),
      label: Text(left.length == 1 ? 'Request 1 episode' : 'Request ${left.length} episodes'),
    );
  }
}
