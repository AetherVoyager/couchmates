import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme.dart';
import '../widgets/poster.dart';

/// A search box over every catalog, with results as a poster grid. Titles in the library open as usual; the
/// rest can be requested from the admin (the Requests tab lists the requests).
class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _query = TextEditingController();
  Timer? _debounce;
  Future<List<SearchHit>>? _results;
  String _searched = '';

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadRequests() async {
    try {
      await context.read<HubSession>().loadRequests();
    } catch (_) {
      // Only the request badges are missing; the Requests tab says what's wrong.
    }
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(text));
  }

  void _search(String text) {
    final q = text.trim();
    if (q == _searched) return;
    final search = context.read<HubSession>().titleSearch;
    setState(() {
      _searched = q;
      _results = q.length < 2 || search == null ? null : search.search(q);
    });
  }

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    final theme = Theme.of(context);
    final box = Padding(
      padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: TextField(
          controller: _query,
          autofocus: true,
          style: theme.textTheme.titleMedium,
          decoration: InputDecoration(
            hintText: 'Search any movie or show',
            prefixIcon: const Icon(Icons.search),
            filled: true,
            fillColor: Colors.black,
            suffixIcon: ListenableBuilder(
              listenable: _query,
              builder: (_, _) => _query.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _query.clear();
                        _search('');
                      },
                    ),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: Colors.white38),
            ),
          ),
          textInputAction: TextInputAction.search,
          onChanged: _changed,
          onSubmitted: _search,
        ),
      ),
    );
    Widget below;
    if (_results == null) {
      below = const MessageView(
        icon: Icons.search,
        message:
            'Type a title to search. If it isn\'t in the library, you can request it. Your requests are in '
            'the Requests tab.',
      );
    } else {
      below = FutureBuilder<List<SearchHit>>(
        future: _results,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return MessageView(icon: Icons.cloud_off, message: errorText(snap.error!));
          final hits = snap.data!;
          if (hits.isEmpty) return MessageView(icon: Icons.search_off, message: 'Nothing found for "$_searched".');
          return SearchGrid(hits: hits, padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 24));
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        box,
        Expanded(child: below),
      ],
    );
  }
}

/// Search results: library titles marked "In library", the rest with a Request button or their request's
/// status.
class SearchGrid extends StatelessWidget {
  const SearchGrid({super.key, required this.hits, this.padding});

  final List<SearchHit> hits;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final inLibrary = hits.where((h) => h.inLibrary).length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding?.left ?? 16, 4, padding?.right ?? 16, 0),
          sliver: SliverToBoxAdapter(
            child: Text(
              inLibrary == 0
                  ? 'None of these are in the library yet. Request the one you want.'
                  : '$inLibrary in the library. Request anything that isn\'t.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Cinema.muted),
            ),
          ),
        ),
        SliverPadding(
          padding: padding ?? const EdgeInsets.all(16),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: posterWidthOf(context) + 24,
              mainAxisSpacing: 24,
              crossAxisSpacing: 14,
              childAspectRatio: posterAspect * 0.82,
            ),
            itemCount: hits.length,
            itemBuilder: (_, i) {
              final hit = hits[i];
              if (hit.inLibrary) {
                return PosterCard(
                  meta: hit.meta,
                  width: double.infinity,
                  caption: true,
                  badge: const StatusChip(label: 'In library', icon: Icons.check_circle),
                );
              }
              if (hit.meta.isSeries) {
                // Shows are asked for by episode, on their page.
                final asked = session.requestsFor(hit.meta);
                return PosterCard(
                  meta: hit.meta,
                  width: double.infinity,
                  caption: true,
                  badge: asked.isEmpty ? null : RequestGroupChip(group: RequestGroup(asked)),
                  footer: asked.isEmpty ? _EpisodesButton(meta: hit.meta) : null,
                );
              }
              final request = session.requestOf(hit.meta);
              return PosterCard(
                meta: hit.meta,
                width: double.infinity,
                caption: true,
                onTap: () => showRequestSheet(context, hit.meta),
                badge: request == null ? null : RequestStatusChip(request: request),
                footer: request == null ? _RequestButton(meta: hit.meta) : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Opens a show's page, where its episodes are asked for.
class _EpisodesButton extends StatelessWidget {
  const _EpisodesButton({required this.meta});

  final StremioMeta meta;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, backgroundColor: Colors.black87),
    onPressed: () => openDetails(context, meta),
    icon: const Icon(Icons.playlist_add, size: 18),
    label: const Text('Request'),
  );
}

class _RequestButton extends StatefulWidget {
  const _RequestButton({required this.meta});

  final StremioMeta meta;

  @override
  State<_RequestButton> createState() => _RequestButtonState();
}

class _RequestButtonState extends State<_RequestButton> {
  bool _busy = false;

  Future<void> _ask() async {
    setState(() => _busy = true);
    await askForTitle(context, widget.meta);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, backgroundColor: Colors.black87),
    onPressed: _busy ? null : _ask,
    icon: _busy
        ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.add, size: 18),
    label: const Text('Request'),
  );
}

/// Asks the admin for [meta] (with [video], that episode of the show) and says how it went.
Future<MediaRequest?> askForTitle(BuildContext context, StremioMeta meta, {StremioVideo? video}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final saved = await context.read<HubSession>().askFor(meta, video: video);
    final others = saved.requestedBy.length - 1;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          others > 0
              ? 'Added you to the request for ${saved.label}. ${others == 1 ? '1 other person' : '$others others'} asked too.'
              : 'Requested ${saved.label}. You\'ll see when the admin answers.',
        ),
      ),
    );
    return saved;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(errorText(e))));
    return null;
  }
}

/// A small dark chip over a poster.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.icon, this.color});

  final String label;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.78), borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c)),
          ],
        ),
      ),
    );
  }
}

/// How each status reads in the app.
(String, IconData, Color) requestStatusLook(String status) => switch (status) {
  RequestStatus.approved => ('Approved', Icons.thumb_up_alt_outlined, const Color(0xFFF5A524)),
  RequestStatus.added => ('Added', Icons.check_circle, const Color(0xFF3ECF8E)),
  RequestStatus.declined => ('Declined', Icons.block, const Color(0xFFF06A6A)),
  _ => ('Requested', Icons.schedule, Cinema.muted),
};

/// The status that matters most for a show's episode requests, with how many.
class RequestGroupChip extends StatelessWidget {
  const RequestGroupChip({super.key, required this.group});

  final RequestGroup group;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = requestStatusLook(group.status);
    final n = group.requests.length;
    return StatusChip(label: group.isEpisodes && n > 1 ? '$label · $n' : label, icon: icon, color: color);
  }
}

class RequestStatusChip extends StatelessWidget {
  const RequestStatusChip({super.key, required this.request});

  final MediaRequest request;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = requestStatusLook(request.status);
    return StatusChip(label: label, icon: icon, color: color);
  }
}

/// A title that isn't in the library: its details, and asking for it.
Future<void> showRequestSheet(BuildContext context, StremioMeta meta) => showDialog<void>(
  context: context,
  builder: (_) => _RequestDialog(meta: meta),
);

class _RequestDialog extends StatefulWidget {
  const _RequestDialog({required this.meta});

  final StremioMeta meta;

  @override
  State<_RequestDialog> createState() => _RequestDialogState();
}

class _RequestDialogState extends State<_RequestDialog> {
  late StremioMeta _meta = widget.meta;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final search = context.read<HubSession>().titleSearch;
    if (search != null && (widget.meta.description ?? '').isEmpty) {
      search.details(widget.meta).then((full) {
        if (mounted) setState(() => _meta = full);
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await action();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = context.watch<HubSession>();
    final request = session.requestOf(widget.meta);
    final meta = _meta;
    final year = meta.releaseInfo ?? meta.year?.toString();
    final facts = [meta.isSeries ? 'Series' : 'Movie', ?year, if (meta.imdbRating != null) 'IMDb ${meta.imdbRating}'];
    final actions = <Widget>[
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      if (request == null)
        FilledButton.icon(
          onPressed: _busy ? null : () => _run(() => askForTitle(context, widget.meta)),
          icon: const Icon(Icons.add),
          label: const Text('Request'),
        )
      else if (!request.mine && request.status != RequestStatus.added)
        FilledButton.icon(
          onPressed: _busy ? null : () => _run(() => askForTitle(context, widget.meta)),
          icon: const Icon(Icons.add),
          label: const Text('I want it too'),
        )
      else if (request.mine && request.open)
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  try {
                    await session.withdrawRequest(request.id);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(errorText(e))));
                    }
                  }
                }),
          child: const Text('Withdraw my request'),
        ),
    ];
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AspectRatio(aspectRatio: posterAspect, child: NetImage(meta.poster)),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(meta.name, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(facts.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: Cinema.muted)),
                    const SizedBox(height: 10),
                    if (request != null) ...[
                      RequestStatusChip(request: request),
                      const SizedBox(height: 6),
                      Text(_requestLine(request), style: theme.textTheme.bodySmall),
                      if (request.note != null) ...[
                        const SizedBox(height: 4),
                        Text('Admin: ${request.note}', style: theme.textTheme.bodySmall?.copyWith(color: Cinema.muted)),
                      ],
                      const SizedBox(height: 10),
                    ],
                    if ((meta.description ?? '').isNotEmpty)
                      Text(meta.description!, maxLines: 8, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 10),
                    Text(
                      'Not in the library. A request goes to the admin, who adds titles by hand.',
                      style: theme.textTheme.bodySmall?.copyWith(color: Cinema.faint),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: actions,
    );
  }
}

String _requestLine(MediaRequest r) {
  final who = r.requestedBy;
  if (who.isEmpty) return 'Nobody is waiting on it';
  if (!r.mine) return 'Asked by ${who.join(', ')}';
  final rest = who.length - 1;
  return rest == 0 ? 'Asked by you' : 'Asked by you and ${rest == 1 ? '1 other' : '$rest others'}';
}

/// [SearchView] as a page of its own.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(), body: const SearchView());
}
