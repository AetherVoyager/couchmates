import 'dart:async';
import 'dart:math';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/updater.dart';
import '../theme.dart';
import '../watch_together/watch_together.dart';
import '../watch_together/watch_together_sheet.dart';
import '../widgets/poster.dart';
import 'catalog_screen.dart';
import 'details_screen.dart';
import 'media_tracks.dart';
import 'play.dart';
import 'profile_screen.dart';
import 'search_screen.dart';

/// What the main area shows: home, search, My list, or one catalog.
sealed class _Page {
  const _Page();
}

class _HomePage extends _Page {
  const _HomePage();
}

class _SearchPage extends _Page {
  const _SearchPage();
}

class _MyListPage extends _Page {
  const _MyListPage();
}

class _CatalogPage extends _Page {
  const _CatalogPage(this.row);

  final HomeRow row;
}

String _catalogKey(StremioCatalog c) => '${c.type}/${c.id}';

/// The signed-in app: a side pane with the catalogue on the left, and home
/// (a featured title over rows of posters), search, My list or a catalog on
/// the right.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<List<HomeRow>>? _rows;
  StremioClient? _loadedFrom;
  _Page _page = const _HomePage();

  /// Pages visited before this one, for Back.
  final _history = <_Page>[];
  bool? _collapsed;
  bool _refreshing = false;

  /// Picks the featured title; new on every load.
  int _seed = Random().nextInt(1 << 30);

  void _load(StremioClient catalog) {
    _loadedFrom = catalog;
    _rows = loadHomeRows(catalog);
    _seed = Random().nextInt(1 << 30);
  }

  /// The refresh button: reloads the config and every row.
  Future<void> _refreshNow() async {
    setState(() => _refreshing = true);
    try {
      await _refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refresh() async {
    final session = context.read<HubSession>();
    await session.refresh();
    final catalog = session.catalog;
    if (catalog == null) return;
    setState(() => _load(catalog));
    await _rows!.then((_) {}, onError: (_) {});
  }

  @override
  void initState() {
    super.initState();
    final updater = context.read<Updater>();
    // After the first frame: checking notifies listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(updater.checkOnStart()));
  }

  void _go(_Page page) {
    if (_samePage(page, _page)) return;
    setState(() {
      if (page is _HomePage) {
        _history.clear();
      } else {
        _history.add(_page);
        if (_history.length > 30) _history.removeAt(0);
      }
      _page = page;
    });
  }

  /// Back to the page before; home when there's none.
  void _back() {
    if (_page is _HomePage) return;
    setState(() => _page = _history.isEmpty ? const _HomePage() : _history.removeLast());
  }

  static bool _samePage(_Page a, _Page b) => switch ((a, b)) {
    (_CatalogPage(row: final x), _CatalogPage(row: final y)) => _catalogKey(x.catalog) == _catalogKey(y.catalog),
    _ => a.runtimeType == b.runtimeType,
  };

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final catalog = session.catalog;
    if (catalog != null && !identical(catalog, _loadedFrom)) _load(catalog);

    return FutureBuilder<List<HomeRow>>(
      future: _rows,
      builder: (context, snap) {
        final rows = snap.data ?? const <HomeRow>[];
        return LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 720;
            final collapsed = _collapsed ?? box.maxWidth < 1100;
            Widget pane(bool collapsed, {VoidCallback? onPicked}) => _SidePane(
              rows: rows,
              page: _page,
              collapsed: collapsed,
              enabled: catalog != null,
              refreshing: _refreshing,
              onRefresh: _refreshing ? null : _refreshNow,
              onToggle: narrow ? null : () => setState(() => _collapsed = !collapsed),
              onGo: (p) {
                onPicked?.call();
                _go(p);
              },
            );
            final content = _Content(
              page: _page,
              catalog: catalog,
              rows: snap,
              seed: _seed,
              onRetry: _refresh,
              onRefresh: _refresh,
              onSeeAll: (row) => _go(_CatalogPage(row)),
              onBack: _back,
            );
            Widget withBack(Widget child) => PopScope(
              // The system back (Android, a mouse's back button through the
              // navigator) steps back through pages before leaving home.
              canPop: _page is _HomePage,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _back();
              },
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): _back,
                  const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back,
                  const SingleActivator(LogicalKeyboardKey.browserBack): _back,
                },
                child: Listener(
                  onPointerDown: (e) {
                    if (e.buttons & kBackMouseButton != 0) _back();
                  },
                  child: Focus(autofocus: true, child: child),
                ),
              ),
            );
            if (narrow) {
              return withBack(
                Scaffold(
                  appBar: AppBar(
                    title: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.asset('assets/couchmates.png', width: 30, height: 30),
                    ),
                    centerTitle: true,
                  ),
                  drawer: Builder(
                    builder: (context) => Drawer(
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
                      child: pane(false, onPicked: () => Navigator.of(context).pop()),
                    ),
                  ),
                  body: content,
                ),
              );
            }
            return withBack(
              Scaffold(
                body: Row(
                  children: [
                    pane(collapsed),
                    Expanded(child: content),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// --- side pane ----------------------------------------------------------------

const _paneWidth = 208.0;
const _collapsedWidth = 64.0;

class _SidePane extends StatelessWidget {
  const _SidePane({
    required this.rows,
    required this.page,
    required this.collapsed,
    required this.enabled,
    required this.refreshing,
    required this.onRefresh,
    required this.onToggle,
    required this.onGo,
  });

  final List<HomeRow> rows;
  final _Page page;
  final bool collapsed;
  final bool enabled;
  final bool refreshing;
  final VoidCallback? onRefresh;
  final VoidCallback? onToggle;
  final ValueChanged<_Page> onGo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inRoom = context.select<WatchTogether, bool>((w) => w.room?.inRoom ?? false);
    final listCount = context.select<Watchlist, int>((w) => w.items.length);

    // The catalogue, grouped by type: Movies, then Shows, in the addon's order.
    final byType = <String, List<HomeRow>>{};
    for (final r in rows) {
      byType.putIfAbsent(r.catalog.type, () => []).add(r);
    }
    final current = page is _CatalogPage ? _catalogKey((page as _CatalogPage).row.catalog) : null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: collapsed ? _collapsedWidth : _paneWidth,
      color: theme.colorScheme.surfaceContainerLowest,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(collapsed ? 0 : 16, 16, collapsed ? 0 : 4, 16),
              child: collapsed
                  ? Center(
                      child: Tooltip(
                        message: 'Expand',
                        child: InkWell(onTap: onToggle, borderRadius: BorderRadius.circular(8), child: _Logo(size: 32)),
                      ),
                    )
                  : Row(
                      children: [
                        const _Logo(size: 32),
                        const Spacer(),
                        if (onToggle != null)
                          IconButton(
                            tooltip: 'Collapse',
                            icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
                            color: theme.colorScheme.onSurfaceVariant,
                            onPressed: onToggle,
                          ),
                      ],
                    ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  _PaneItem(
                    icon: Icons.home_outlined,
                    selectedIcon: Icons.home_rounded,
                    label: 'Home',
                    selected: page is _HomePage,
                    collapsed: collapsed,
                    onTap: () => onGo(const _HomePage()),
                  ),
                  _PaneItem(
                    icon: Icons.search_rounded,
                    label: 'Search',
                    selected: page is _SearchPage,
                    collapsed: collapsed,
                    onTap: enabled ? () => onGo(const _SearchPage()) : null,
                  ),
                  _PaneItem(
                    icon: Icons.bookmark_border_rounded,
                    selectedIcon: Icons.bookmark_rounded,
                    label: 'My list',
                    trailing: listCount > 0 ? '$listCount' : null,
                    selected: page is _MyListPage,
                    collapsed: collapsed,
                    onTap: () => onGo(const _MyListPage()),
                  ),
                  _PaneItem(
                    icon: Icons.groups_outlined,
                    selectedIcon: Icons.groups_rounded,
                    label: 'Watch together',
                    badge: inRoom,
                    selected: false,
                    collapsed: collapsed,
                    onTap: enabled ? () => showWatchTogetherSheet(context) : null,
                  ),
                  if (byType.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    if (collapsed)
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: Divider())
                    else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(19, 12, 12, 6),
                        child: Text(
                          'CATALOGUE',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Cinema.faint,
                            letterSpacing: 1.6,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    for (final MapEntry(key: type, value: list) in byType.entries) ...[
                      if (!collapsed && byType.length > 1)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(19, 10, 12, 2),
                          child: Text(
                            typeLabel(type),
                            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      for (final row in list)
                        _PaneItem(
                          icon: switch (type) {
                            'movie' => Icons.movie_outlined,
                            'series' => Icons.tv_rounded,
                            _ => Icons.video_library_outlined,
                          },
                          label: byType.length > 1 ? row.catalog.name : row.title,
                          tooltip: row.title,
                          dense: true,
                          selected: current == _catalogKey(row.catalog),
                          collapsed: collapsed,
                          onTap: () => onGo(_CatalogPage(row)),
                        ),
                    ],
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 8, vertical: 6),
              child: collapsed
                  ? Column(
                      children: [
                        _RefreshButton(refreshing: refreshing, onPressed: onRefresh),
                        const ProfileButton(),
                      ],
                    )
                  : Row(
                      children: [
                        const Expanded(child: ProfileButton(showName: true)),
                        _RefreshButton(refreshing: refreshing, onPressed: onRefresh),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size / 4),
    child: Image.asset('assets/couchmates.png', width: size, height: size, semanticLabel: 'Couchmates'),
  );
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.refreshing, required this.onPressed});

  final bool refreshing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Refresh',
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    icon: refreshing
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.refresh_rounded),
    onPressed: onPressed,
  );
}

class _PaneItem extends StatefulWidget {
  const _PaneItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    this.selectedIcon,
    this.tooltip,
    this.trailing,
    this.badge = false,
    this.dense = false,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final String? tooltip;
  final String? trailing;
  final bool selected;
  final bool collapsed;
  final bool badge;
  final bool dense;
  final VoidCallback? onTap;

  @override
  State<_PaneItem> createState() => _PaneItemState();
}

class _PaneItemState extends State<_PaneItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = widget;
    final active = w.selected || _hover;
    final color = w.onTap == null
        ? Cinema.faint.withValues(alpha: 0.5)
        : active
        ? Colors.white
        : Cinema.muted;
    Widget icon = Icon(w.selected ? (w.selectedIcon ?? w.icon) : w.icon, size: w.dense ? 20 : 22, color: color);
    if (w.badge) icon = Badge(smallSize: 8, backgroundColor: theme.colorScheme.primary, child: icon);
    final item = InkWell(
      onTap: w.onTap,
      onHover: (h) => setState(() => _hover = h),
      child: Container(
        height: w.dense ? 40 : 46,
        padding: EdgeInsets.only(left: w.collapsed ? 0 : 16, right: 10),
        decoration: BoxDecoration(
          color: w.selected ? Colors.white.withValues(alpha: 0.06) : null,
          border: Border(
            left: BorderSide(color: w.selected ? theme.colorScheme.primary : Colors.transparent, width: 3),
          ),
        ),
        child: w.collapsed
            ? Center(child: icon)
            : Row(
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      w.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (w.dense ? theme.textTheme.bodyMedium : theme.textTheme.titleSmall)?.copyWith(
                        color: color,
                        fontWeight: w.selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (w.trailing != null)
                    Text(w.trailing!, style: theme.textTheme.labelMedium?.copyWith(color: Cinema.faint)),
                ],
              ),
      ),
    );
    return w.collapsed || w.tooltip != null
        ? Tooltip(message: w.tooltip ?? w.label, preferBelow: false, child: item)
        : item;
  }
}

// --- main area --------------------------------------------------------------

class _Content extends StatelessWidget {
  const _Content({
    required this.page,
    required this.catalog,
    required this.rows,
    required this.seed,
    required this.onRetry,
    required this.onRefresh,
    required this.onSeeAll,
    required this.onBack,
  });

  final _Page page;
  final StremioClient? catalog;
  final AsyncSnapshot<List<HomeRow>> rows;
  final int seed;
  final Future<void> Function() onRetry;
  final Future<void> Function() onRefresh;
  final ValueChanged<HomeRow> onSeeAll;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<HubSession>();
    final updater = context.watch<Updater>();
    final Widget body;
    if (catalog == null) {
      body = MessageView(
        icon: Icons.video_library_outlined,
        message: session.problem != null
            ? 'Your catalog will show up once the Hub can be reached.'
            : 'Nothing to watch yet. Your admin still has to connect the catalog.',
        onRetry: onRetry,
      );
    } else {
      body = switch (page) {
        _HomePage() => _HomeFeed(rows: rows, seed: seed, onRetry: onRetry, onRefresh: onRefresh, onSeeAll: onSeeAll),
        _SearchPage() => const SearchView(),
        _MyListPage() => const _MyListView(),
        _CatalogPage(:final row) => CatalogView(
          key: ValueKey(_catalogKey(row.catalog)),
          catalog: row.catalog,
          title: row.catalog.name,
          subtitle: typeLabel(row.catalog.type),
          onBack: onBack,
        ),
      };
    }
    return Column(
      children: [
        if (updater.showBanner)
          MaterialBanner(
            leading: const Icon(Icons.system_update_alt),
            content: Text('Couchmates ${updater.info!.latestVersion} is available.'),
            actions: [
              TextButton(onPressed: updater.dismiss, child: const Text('Later')),
              FilledButton(onPressed: updater.install, child: const Text('Update now')),
            ],
          ),
        if (updater.progress != null)
          MaterialBanner(
            leading: const Icon(Icons.downloading),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Downloading the update… ${(updater.progress! * 100).round()}%'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: updater.progress),
              ],
            ),
            actions: const [SizedBox.shrink()],
          ),
        if (session.problem != null)
          MaterialBanner(
            content: Text(session.problem!),
            actions: [TextButton(onPressed: onRetry, child: const Text('Retry'))],
          ),
        Expanded(child: body),
      ],
    );
  }
}

class _MyListView extends StatelessWidget {
  const _MyListView();

  @override
  Widget build(BuildContext context) {
    final items = context.watch<Watchlist>().items;
    final gutter = pageGutter(context);
    final header = Padding(
      padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 4),
      child: Text('My list', style: Theme.of(context).textTheme.headlineMedium),
    );
    if (items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const Expanded(
            child: MessageView(
              icon: Icons.bookmark_border_rounded,
              message: 'Titles you save with the bookmark button on a details page show up here.',
            ),
          ),
        ],
      );
    }
    return PosterGrid(items: items, header: header, padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 24));
  }
}

class _HomeFeed extends StatelessWidget {
  const _HomeFeed({
    required this.rows,
    required this.seed,
    required this.onRetry,
    required this.onRefresh,
    required this.onSeeAll,
  });

  final AsyncSnapshot<List<HomeRow>> rows;
  final int seed;
  final Future<void> Function() onRetry;
  final Future<void> Function() onRefresh;
  final ValueChanged<HomeRow> onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (rows.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
    if (rows.hasError) return MessageView(icon: Icons.cloud_off, message: errorText(rows.error!), onRetry: onRetry);
    final list = rows.data!;
    if (list.isEmpty) {
      return MessageView(
        icon: Icons.movie_outlined,
        message:
            "Nothing to show yet. If your admin has added movies or shows, they may not be shared with "
            'your account: ask them to run "Check catalog" on your user in the Hub.',
        onRetry: onRetry,
      );
    }
    // The featured title: one with a backdrop, picked at random per load.
    final withArt = [for (final r in list) ...r.items.where((m) => m.background != null)];
    final featured = withArt.isEmpty ? null : withArt[seed % withArt.length];
    final continuing = context.watch<ProgressStore>().continueWatching;
    final saved = context.watch<Watchlist>().items;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          if (featured != null) _Billboard(key: ValueKey(featured.id), item: featured) else const SizedBox(height: 20),
          if (continuing.isNotEmpty)
            _Shelf(
              title: 'Continue watching',
              itemCount: continuing.length,
              itemWidth: posterWidthOf(context) * 1.9,
              height: posterWidthOf(context) * 1.9 * 9 / 16 + 30,
              itemBuilder: (context, i, width) {
                final p = continuing[i];
                return LandscapeCard(meta: p.meta, width: width, progress: p.fraction, subtitle: p.videoTitle);
              },
            ),
          if (saved.isNotEmpty)
            _Shelf(
              title: 'My list',
              itemCount: saved.length,
              itemWidth: posterWidthOf(context),
              height: posterWidthOf(context) / posterAspect,
              itemBuilder: (context, i, width) => PosterCard(meta: saved[i], width: width),
            ),
          for (final row in list)
            _Shelf(
              title: row.title,
              onSeeAll: () => onSeeAll(row),
              itemCount: row.items.length,
              itemWidth: posterWidthOf(context),
              height: posterWidthOf(context) / posterAspect,
              itemBuilder: (context, i, width) => PosterCard(meta: row.items[i], width: width),
            ),
        ],
      ),
    );
  }
}

/// A big backdrop of one title with its logo, a few facts, the description,
/// and Play and More info.
class _Billboard extends StatefulWidget {
  const _Billboard({super.key, required this.item});

  final StremioMeta item;

  @override
  State<_Billboard> createState() => _BillboardState();
}

class _BillboardState extends State<_Billboard> {
  late final Future<StremioMeta?> _full = context
      .read<HubSession>()
      .catalog!
      .meta(widget.item.type, widget.item.id)
      .then<StremioMeta?>((m) => m, onError: (_) => null);

  @override
  void initState() {
    super.initState();
    // Its Play and More info are the likeliest clicks: have the tracks ready.
    WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? prefetchTracks(context, widget.item) : null);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = (size.height * 0.62).clamp(340.0, 640.0);
    final gutter = pageGutter(context);
    final theme = Theme.of(context);
    final bg = theme.colorScheme.surface;
    return FutureBuilder<StremioMeta?>(
      future: _full,
      builder: (context, snap) {
        final meta = snap.data ?? widget.item;
        final title = Text(
          meta.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.displaySmall?.copyWith(
            color: Colors.white,
            shadows: const [Shadow(blurRadius: 12, color: Colors.black54)],
          ),
        );
        final facts = [
          ?(meta.releaseInfo ?? meta.year?.toString()),
          ?meta.runtime,
          if (meta.imdbRating != null) '★ ${meta.imdbRating!.toStringAsFixed(1)}',
          ...meta.genres.take(3),
        ];
        return SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetImage(meta.background, alignment: Alignment.topCenter),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: const [0, 0.45, 0.85],
                    colors: [bg.withValues(alpha: 0.92), bg.withValues(alpha: 0.45), Colors.transparent],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.55, 1],
                    colors: [Colors.transparent, bg],
                  ),
                ),
              ),
              Positioned(
                left: gutter,
                bottom: 36,
                width: min(560, size.width * 0.6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (meta.logo != null)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 130, maxWidth: 440),
                        child: Image.network(
                          meta.logo!,
                          fit: BoxFit.contain,
                          alignment: Alignment.bottomLeft,
                          errorBuilder: (_, _, _) => title,
                          semanticLabel: meta.name,
                        ),
                      )
                    else
                      title,
                    if (facts.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        facts.join('  ·  '),
                        style: theme.textTheme.titleSmall?.copyWith(color: Colors.white.withValues(alpha: 0.9)),
                      ),
                    ],
                    if (meta.description != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        meta.description!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.white,
                          shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        PlayButton(onPressed: () => _play(context, meta)),
                        FilledButton.icon(
                          onPressed: () => openDetails(context, meta),
                          icon: const Icon(Icons.info_outline_rounded),
                          label: const Text('More info'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.grey.withValues(alpha: 0.45),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            textStyle: theme.textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _play(BuildContext context, StremioMeta meta) {
    if (!meta.isSeries) {
      unawaited(playTitle(context, meta: meta));
      return;
    }
    if (meta.videos.isEmpty) return openDetails(context, meta);
    final progress = context.read<ProgressStore>();
    final video = continueEpisode(progress, meta) ?? meta.episodesOf(meta.seasons.first).firstOrNull;
    unawaited(playTitle(context, meta: meta, video: video));
  }
}

/// The white Play button.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.onPressed, this.label = 'Play'});

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    icon: const Icon(Icons.play_arrow_rounded, size: 30),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.fromLTRB(18, 0, 26, 0),
      textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

/// A titled row that scrolls sideways, with arrows at the edges under the
/// mouse (a mouse wheel can't scroll it).
class _Shelf extends StatefulWidget {
  const _Shelf({
    required this.title,
    required this.itemCount,
    required this.itemWidth,
    required this.height,
    required this.itemBuilder,
    this.onSeeAll,
  });

  final String title;
  final int itemCount;
  final double itemWidth;
  final double height;
  final Widget Function(BuildContext context, int index, double width) itemBuilder;
  final VoidCallback? onSeeAll;

  @override
  State<_Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<_Shelf> {
  final _scroll = ScrollController();
  bool _hover = false;
  bool _atStart = true;
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_edges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _edges());
  }

  void _edges() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    final start = p.pixels <= 1, end = p.pixels >= p.maxScrollExtent - 1;
    if (start != _atStart || end != _atEnd) {
      setState(() {
        _atStart = start;
        _atEnd = end;
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _page(int dir) {
    final p = _scroll.position;
    final to = (p.pixels + dir * p.viewportDimension * 0.85).clamp(0.0, p.maxScrollExtent);
    unawaited(_scroll.animateTo(to, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    // Room for the hover zoom and its shadow.
    const bleed = 14.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(fontSize: 20),
                  ),
                ),
                if (widget.onSeeAll != null)
                  AnimatedOpacity(
                    opacity: _hover ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: TextButton(
                      onPressed: widget.onSeeAll,
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [Text('Explore all'), Icon(Icons.chevron_right_rounded, size: 18)],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: widget.height + bleed * 2,
            child: Stack(
              children: [
                ListView.separated(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: EdgeInsets.symmetric(horizontal: gutter, vertical: bleed),
                  itemCount: widget.itemCount,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => widget.itemBuilder(context, i, widget.itemWidth),
                ),
                if (!_atStart) _arrow(left: true, gutter: gutter, bleed: bleed),
                if (!_atEnd) _arrow(left: false, gutter: gutter, bleed: bleed),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrow({required bool left, required double gutter, required double bleed}) {
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: bleed,
      bottom: bleed,
      width: gutter,
      child: AnimatedOpacity(
        opacity: _hover ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: Material(
          color: Colors.black.withValues(alpha: 0.55),
          child: InkWell(
            onTap: () => _page(left ? -1 : 1),
            child: Icon(left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded, size: 36, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
