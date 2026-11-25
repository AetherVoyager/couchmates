import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../theme.dart';
import '../widgets/poster.dart';
import 'play.dart';
import 'search_screen.dart';
import '../widgets/toasts.dart';

/// The Requests tab: the user's requests and everyone's (most wanted first), the requested titles that just
/// reached the library, and the next episodes of requested shows.
class RequestsView extends StatefulWidget {
  const RequestsView({super.key});

  @override
  State<RequestsView> createState() => _RequestsViewState();
}

class _RequestsViewState extends State<RequestsView> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 4, vsync: this);
  Object? _error;

  /// What the lookups below were made for, so they only run again when the requests that matter change.
  String? _arrivedFor, _upcomingFor;
  Future<List<ArrivedTitle>>? _arrived;
  Future<List<UpcomingEpisode>>? _upcoming;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await context.read<HubSession>().loadRequests();
      if (!mounted) return;
      setState(() => _error = null);
      // The requests are on screen now, so their answers count as seen.
      await context.read<RequestUpdates?>()?.markSeen();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _reload() async {
    _arrivedFor = _upcomingFor = null;
    await _load();
  }

  /// Starts the library and catalog lookups for [groups] when what they depend on changed.
  void _lookUp(HubSession session, List<RequestGroup> groups) {
    final search = session.titleSearch;
    if (search == null) return;
    final added = [
      for (final g in groups)
        for (final r in g.requests)
          if (r.status == RequestStatus.added) '${r.id}@${r.updatedAt}',
    ].join(',');
    if (added != _arrivedFor) {
      _arrivedFor = added;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _arrived = findArrived(search, groups, nowSeconds: now);
    }
    final shows = [
      for (final g in groups)
        if (g.first.kind == 'series') '${g.first.titleId}:${g.status}',
    ].join(',');
    if (shows != _upcomingFor) {
      _upcomingFor = shows;
      _upcoming = findUpcoming(search, groups);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final gutter = pageGutter(context);

    final Widget body;
    if (!session.requestsLoaded) {
      body = _error != null
          ? MessageView(icon: Icons.cloud_off, message: errorText(_error!), onRetry: _reload)
          : const Center(child: CircularProgressIndicator());
    } else {
      final all = groupRequests(session.requests);
      _lookUp(session, all);
      final shown = withoutCleared(all, settings.get(Settings.requestsClearedAt));
      final mine = mostWanted(shown.where((g) => g.mine).toList());
      final everyone = mostWanted(shown);
      body = TabBarView(
        controller: _tabs,
        children: [
          RequestsList(
            groups: mine,
            padding: gutter,
            onRefresh: _reload,
            empty:
                'You haven\'t asked for anything yet. Search for a title, and if it isn\'t in the library, '
                'request it.',
          ),
          RequestsList(
            groups: everyone,
            padding: gutter,
            onRefresh: _reload,
            empty: 'Nobody has asked for anything yet.',
          ),
          _JustAdded(future: _arrived, padding: gutter, onRefresh: _reload),
          _ComingSoon(future: _upcoming, padding: gutter, onRefresh: _reload),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 4),
          child: Text('Requests', style: theme.textTheme.headlineSmall),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter - 12),
          child: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            tabs: const [
              Tab(text: 'My requests'),
              Tab(text: 'All requests'),
              Tab(text: 'Just added'),
              Tab(text: 'Coming soon'),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

/// Requests by title, with their status, the admin's note, who asked, and Withdraw or "I want it too". Answered
/// ones (Added or Declined) can be cleared from the list; waiting ones always show.
class RequestsList extends StatelessWidget {
  const RequestsList({super.key, required this.groups, required this.empty, this.onRefresh, this.padding = 24});

  final List<RequestGroup> groups;
  final String empty;
  final Future<void> Function()? onRefresh;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppSettings>();
    if (groups.isEmpty) return MessageView(icon: Icons.inbox_outlined, message: empty);
    final finished = groups.where((g) => g.finished).toList();
    return RefreshIndicator(
      onRefresh: () async => onRefresh?.call(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (finished.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 8, padding, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  // The Hub's own times, so this device's clock doesn't matter.
                  onPressed: () => settings.set(
                    Settings.requestsClearedAt,
                    finished.map((g) => g.changedAt).reduce((a, b) => a > b ? a : b),
                  ),
                  icon: const Icon(Icons.clear_all),
                  label: Text('Clear ${finished.length} answered'),
                ),
              ),
            ),
          for (final g in groups)
            Padding(
              key: ValueKey('${g.first.kind}/${g.first.titleId}'),
              padding: EdgeInsets.symmetric(horizontal: padding - 16),
              child: RequestTile(group: g),
            ),
        ],
      ),
    );
  }
}

/// One movie or show and its requests.
class RequestTile extends StatefulWidget {
  const RequestTile({super.key, required this.group});

  final RequestGroup group;

  @override
  State<RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends State<RequestTile> {
  bool _busy = false;

  Future<void> _run(Future<String?> Function(HubSession session) action) async {
    final session = context.read<HubSession>();
    setState(() => _busy = true);
    try {
      final said = await action(session);
      if (said != null) toasts.success(said);
    } catch (e) {
      toasts.error(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = widget.group;
    final r = group.first;
    final askers = group.askers;
    final who = group.mine
        ? (askers.length <= 1 ? 'You asked' : 'You and ${_others(askers.length - 1)} asked')
        : (askers.isEmpty
              ? null
              : 'Asked by ${askers.take(3).join(', ')}${askers.length > 3 ? ' +${askers.length - 3}' : ''}');
    final subtitle = [r.kind == 'series' ? 'Series' : 'Movie', ?r.year, ?group.episodesText, ?who].join(' · ');
    final notes = {for (final x in group.requests) ?x.note}.toList();
    final withdraw = group.withdrawable;
    final join = group.joinable;

    final Widget? action;
    if (join.isNotEmpty) {
      action = FilledButton.tonalIcon(
        onPressed: _busy
            ? null
            : () => _run((s) async {
                final n = await s.joinRequests(group);
                return n == 0 ? null : 'Added you to the request for ${r.name}.';
              }),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('I want it too'),
      );
    } else if (withdraw.isNotEmpty) {
      action = OutlinedButton(
        onPressed: _busy
            ? null
            : () => _run((s) async {
                await s.withdrawRequests(withdraw.map((x) => x.id));
                return 'Withdrew your request for ${r.name}.';
              }),
        child: const Text('Withdraw'),
      );
    } else {
      action = null;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SizedBox(
        width: 44,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: AspectRatio(aspectRatio: posterAspect, child: NetImage(r.poster)),
        ),
      ),
      title: Row(
        children: [
          Flexible(child: Text(r.name, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 10),
          group.isEpisodes ? RequestGroupChip(group: group) : RequestStatusChip(request: r),
          if (group.waiting && askers.length > 1) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: askers.join(', '),
              child: StatusChip(label: '${askers.length} want it', icon: Icons.local_fire_department_rounded),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: Cinema.muted)),
          for (final n in notes.take(2)) Text('Admin: $n', style: theme.textTheme.bodySmall),
        ],
      ),
      trailing: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : action,
      onTap: () => group.isEpisodes || r.kind == 'series' || r.status == RequestStatus.added
          ? openDetails(context, group.meta)
          : showRequestSheet(context, group.meta),
    );
  }
}

String _others(int n) => n == 1 ? '1 other' : '$n others';

/// Requested titles that reached the library in the last month, each with Play.
class _JustAdded extends StatelessWidget {
  const _JustAdded({required this.future, required this.padding, required this.onRefresh});

  final Future<List<ArrivedTitle>>? future;
  final double padding;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (future == null) return const MessageView(icon: Icons.cloud_off, message: 'The library can\'t be reached.');
    return FutureBuilder<List<ArrivedTitle>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final list = snap.data ?? const [];
        if (list.isEmpty) {
          return MessageView(
            icon: Icons.new_releases_outlined,
            message: 'Nothing new yet. Requested titles show up here once they\'re in the library.',
            onRetry: onRefresh,
          );
        }
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(padding, 16, padding, 24),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: posterWidthOf(context) + 24,
            mainAxisSpacing: 24,
            crossAxisSpacing: 14,
            childAspectRatio: posterAspect * 0.82,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final a = list[i];
            final v = a.video;
            final more = a.episodes.length - 1;
            final label = v == null
                ? (a.group.mine ? 'You asked' : 'New')
                : 'S${v.season} E${v.episode}${more > 0 ? ' +$more' : ''}';
            return PosterCard(
              meta: a.meta,
              width: double.infinity,
              caption: true,
              badge: StatusChip(label: label, icon: Icons.check_circle, color: const Color(0xFF3ECF8E)),
              footer: FilledButton.icon(
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => unawaited(playTitle(context, meta: a.meta, video: v)),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Play'),
              ),
            );
          },
        );
      },
    );
  }
}

/// The next episode of each requested show, soonest first.
class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.future, required this.padding, required this.onRefresh});

  final Future<List<UpcomingEpisode>>? future;
  final double padding;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (future == null) return const MessageView(icon: Icons.cloud_off, message: 'The catalogs can\'t be reached.');
    final theme = Theme.of(context);
    return FutureBuilder<List<UpcomingEpisode>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final list = snap.data ?? const [];
        if (list.isEmpty) {
          return MessageView(
            icon: Icons.event_outlined,
            message: 'No new episodes announced for the shows people asked for.',
            onRetry: onRefresh,
          );
        }
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            for (final u in list)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: padding - 16),
                child: ListTile(
                  leading: SizedBox(
                    width: 44,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: AspectRatio(
                        aspectRatio: posterAspect,
                        child: NetImage(u.show.poster ?? u.group.first.poster),
                      ),
                    ),
                  ),
                  title: Text(u.show.name),
                  subtitle: Text(
                    [
                      'S${u.video.season} E${u.video.episode}',
                      if (u.video.title.trim().isNotEmpty) u.video.title.trim(),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(color: Cinema.muted),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(airsText(u.airs), style: theme.textTheme.labelLarge),
                      Text(
                        DateFormat.MMMd().format(u.airs.toLocal()),
                        style: theme.textTheme.bodySmall?.copyWith(color: Cinema.muted),
                      ),
                    ],
                  ),
                  onTap: () => openDetails(context, u.group.meta),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// "Tomorrow", "In 5 days", "In 3 weeks".
String airsText(DateTime airs, {DateTime? now}) {
  final today = DateUtils.dateOnly((now ?? DateTime.now()).toLocal());
  final days = DateUtils.dateOnly(airs.toLocal()).difference(today).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days < 14) return 'In $days days';
  if (days < 60) return 'In ${(days / 7).round()} weeks';
  return 'In ${(days / 30).round()} months';
}
