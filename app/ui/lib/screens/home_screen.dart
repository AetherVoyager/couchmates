import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

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

  /// Keeps the side pane open beside the page instead of folded over it.
  bool _pinned = false;
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
            Widget pane({required bool pinned, VoidCallback? onPin, VoidCallback? onPicked}) => _SidePane(
              rows: rows,
              page: _page,
              pinned: pinned,
              enabled: catalog != null,
              refreshing: _refreshing,
              onRefresh: _refreshing ? null : _refreshNow,
              onTogglePin: onPin,
              onGo: (p) {
                onPicked?.call();
                _go(p);
              },
            );
            Widget content(double inset) => _Content(
              page: _page,
              catalog: catalog,
              rows: snap,
              seed: _seed,
              inset: inset,
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
                  appBar: AppBar(title: const _Logo(size: 30), centerTitle: true),
                  drawer: Builder(
                    builder: (context) => Drawer(
                      width: _paneWidth,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
                      child: pane(pinned: true, onPicked: () => Navigator.of(context).pop()),
                    ),
                  ),
                  body: content(0),
                ),
              );
            }
            void togglePin() => setState(() => _pinned = !_pinned);
            if (_pinned) {
              return withBack(
                Scaffold(
                  body: Row(
                    children: [
                      pane(pinned: true, onPin: togglePin),
                      Expanded(child: content(0)),
                    ],
                  ),
                ),
              );
            }
            // The rail floats over the page, so the home hero runs under it;
            // the page keeps clear of its folded width.
            return withBack(
              Scaffold(
                body: Stack(
                  children: [
                    Positioned.fill(child: content(_railWidth)),
                    Positioned(left: 0, top: 0, bottom: 0, child: pane(pinned: false, onPin: togglePin)),
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

/// Folded: icons only. Open: labels and the catalogue.
const _railWidth = 76.0;
const _paneWidth = 264.0;

/// Where the icons sit, so they stay put while the pane opens.
const _railInset = 16.0;
const _iconBox = 44.0;
const _labelStart = _railInset + _iconBox + 14;

/// The app's navigation. Pinned, it stays open beside the page; otherwise it
/// is a slim rail of icons over the page that opens while the mouse or the
/// keyboard is on it.
class _SidePane extends StatefulWidget {
  const _SidePane({
    required this.rows,
    required this.page,
    required this.pinned,
    required this.enabled,
    required this.refreshing,
    required this.onRefresh,
    required this.onTogglePin,
    required this.onGo,
  });

  final List<HomeRow> rows;
  final _Page page;
  final bool pinned;
  final bool enabled;
  final bool refreshing;
  final VoidCallback? onRefresh;

  /// Null where pinning doesn't apply (the narrow window's drawer).
  final VoidCallback? onTogglePin;
  final ValueChanged<_Page> onGo;

  @override
  State<_SidePane> createState() => _SidePaneState();
}

class _SidePaneState extends State<_SidePane> {
  bool _hover = false;
  bool _focus = false;
  Timer? _opening;

  bool get _open => widget.pinned || _hover || _focus;

  void _setHover(bool hover) {
    _opening?.cancel();
    if (hover) {
      // A short wait, so passing over the rail on the way somewhere doesn't
      // open it.
      _opening = Timer(const Duration(milliseconds: 140), () {
        if (mounted) setState(() => _hover = true);
      });
    } else if (_hover) {
      setState(() => _hover = false);
    }
  }

  void _setFocus(bool focus) {
    // Only keyboard focus opens it: a click leaves focus behind, which would
    // keep it open after the mouse has gone.
    final keyboard = FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final open = focus && keyboard;
    if (open != _focus) setState(() => _focus = open);
  }

  @override
  void dispose() {
    _opening?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final w = widget;
    final open = _open;
    final floating = open && !w.pinned;
    final inRoom = context.select<WatchTogether, bool>((w) => w.room?.inRoom ?? false);
    final listCount = context.select<Watchlist, int>((w) => w.items.length);
    // An answer to one of the user's requests they haven't seen in Search yet.
    final unseenRequests = context.select<RequestUpdates, bool>((u) => u.hasUnseen);

    // The catalogue, grouped by type: Movies, then Shows, in the addon's order.
    final byType = <String, List<HomeRow>>{};
    for (final r in w.rows) {
      byType.putIfAbsent(r.catalog.type, () => []).add(r);
    }
    final page = w.page;
    final current = page is _CatalogPage ? _catalogKey(page.row.catalog) : null;

    // Folded, a soft scrim keeps the icons readable over artwork; open, a
    // solid panel. Both are gradients so the change animates.
    final Gradient fill = open
        ? LinearGradient(
            colors: [
              scheme.surfaceContainerLowest.withValues(alpha: w.pinned ? 1 : 0.94),
              scheme.surfaceContainerLowest.withValues(alpha: w.pinned ? 1 : 0.9),
            ],
          )
        : LinearGradient(colors: [scheme.surface.withValues(alpha: 0.72), scheme.surface.withValues(alpha: 0)]);

    final body = SizedBox(
      width: _paneWidth,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(_railInset, 20, 10, 22),
              child: Row(
                children: [
                  Tooltip(
                    message: w.onTogglePin == null ? 'Couchmates' : (w.pinned ? 'Fold the menu' : 'Keep the menu open'),
                    child: InkWell(
                      onTap: w.onTogglePin,
                      borderRadius: BorderRadius.circular(12),
                      child: const _Logo(size: _iconBox),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _FadeLabel(
                      visible: open,
                      child: Text(
                        'Couchmates',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: theme.textTheme.titleLarge?.copyWith(fontSize: 21),
                      ),
                    ),
                  ),
                  if (w.onTogglePin != null)
                    _FadeLabel(
                      visible: open,
                      child: IconButton(
                        tooltip: w.pinned ? 'Fold the menu' : 'Keep the menu open',
                        iconSize: 20,
                        color: w.pinned ? scheme.primary : Cinema.faint,
                        icon: Icon(w.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
                        onPressed: w.onTogglePin,
                      ),
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
                    open: open,
                    onTap: () => w.onGo(const _HomePage()),
                  ),
                  _PaneItem(
                    icon: Icons.search_rounded,
                    label: 'Search',
                    badge: unseenRequests,
                    selected: page is _SearchPage,
                    open: open,
                    onTap: w.enabled ? () => w.onGo(const _SearchPage()) : null,
                  ),
                  _PaneItem(
                    icon: Icons.bookmark_border_rounded,
                    selectedIcon: Icons.bookmark_rounded,
                    label: 'My list',
                    trailing: listCount > 0 ? '$listCount' : null,
                    selected: page is _MyListPage,
                    open: open,
                    onTap: () => w.onGo(const _MyListPage()),
                  ),
                  _PaneItem(
                    icon: Icons.groups_outlined,
                    selectedIcon: Icons.groups_rounded,
                    label: 'Watch together',
                    badge: inRoom,
                    selected: false,
                    open: open,
                    onTap: w.enabled ? () => showWatchTogetherSheet(context) : null,
                  ),
                  if (byType.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    // Folded, one icon stands for the catalogue: a tap opens
                    // the menu (for touch, where nothing hovers).
                    _PaneItem(
                      icon: Icons.video_library_outlined,
                      selectedIcon: Icons.video_library_rounded,
                      label: 'Catalogue',
                      heading: open,
                      selected: !open && current != null,
                      open: open,
                      onTap: open ? null : w.onTogglePin,
                    ),
                    if (open)
                      for (final MapEntry(key: type, value: list) in byType.entries) ...[
                        if (byType.length > 1)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(_labelStart, 10, 16, 4),
                            child: Text(
                              typeLabel(type),
                              style: theme.textTheme.labelMedium?.copyWith(color: Cinema.faint),
                            ),
                          ),
                        for (final row in list)
                          _CatalogItem(
                            label: byType.length > 1 ? row.catalog.name : row.title,
                            tooltip: row.title,
                            selected: current == _catalogKey(row.catalog),
                            onTap: () => w.onGo(_CatalogPage(row)),
                          ),
                      ],
                  ],
                ],
              ),
            ),
            Padding(
              // Puts the 34 px avatar (inside the button's 6 px padding) under the icons.
              padding: const EdgeInsets.fromLTRB(_railInset + (_iconBox - 34) / 2 - 6, 6, 10, 10),
              child: Row(
                children: [
                  Expanded(child: ProfileButton(showName: open)),
                  _FadeLabel(
                    visible: open,
                    child: _RefreshButton(refreshing: w.refreshing, onPressed: w.onRefresh),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: _setFocus,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: open ? _paneWidth : _railWidth,
          decoration: BoxDecoration(
            gradient: fill,
            border: Border(
              right: BorderSide(color: open ? scheme.outlineVariant.withValues(alpha: 0.7) : Colors.transparent),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: floating ? 0.55 : 0),
                blurRadius: 48,
                offset: const Offset(12, 0),
              ),
            ],
          ),
          child: ClipRect(
            child: BackdropFilter(
              enabled: floating,
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              // Laid out at the open width and clipped while folded, so
              // nothing reflows as it opens.
              child: OverflowBox(alignment: Alignment.topLeft, minWidth: _paneWidth, maxWidth: _paneWidth, child: body),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades with the pane opening and folding.
class _FadeLabel extends StatelessWidget {
  const _FadeLabel({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: Duration(milliseconds: visible ? 260 : 120),
    curve: Curves.easeOut,
    child: IgnorePointer(ignoring: !visible, child: child),
  );
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
    color: Cinema.faint,
    icon: refreshing
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.refresh_rounded),
    onPressed: onPressed,
  );
}

/// A destination: its icon in a rounded tile that lights up when selected,
/// and the label beside it once the pane is open.
class _PaneItem extends StatefulWidget {
  const _PaneItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.open,
    required this.onTap,
    this.selectedIcon,
    this.trailing,
    this.badge = false,
    this.heading = false,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final String? trailing;
  final bool selected;
  final bool open;
  final bool badge;

  /// Shown as the heading of what follows, not as something to click.
  final bool heading;
  final VoidCallback? onTap;

  @override
  State<_PaneItem> createState() => _PaneItemState();
}

class _PaneItemState extends State<_PaneItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final w = widget;
    final disabled = w.onTap == null && !w.heading;
    final hover = _hover && w.onTap != null;
    final Color iconColor = disabled
        ? Cinema.faint.withValues(alpha: 0.5)
        : w.selected
        ? scheme.primary
        : hover
        ? Colors.white
        : Cinema.muted;
    final Color labelColor = disabled
        ? Cinema.faint.withValues(alpha: 0.5)
        : w.selected || hover
        ? Colors.white
        : w.heading
        ? Cinema.faint
        : Cinema.muted;
    Widget icon = Icon(w.selected ? (w.selectedIcon ?? w.icon) : w.icon, size: 22, color: iconColor);
    if (w.badge) icon = Badge(smallSize: 8, backgroundColor: scheme.primary, child: icon);
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: _iconBox,
      height: _iconBox,
      decoration: BoxDecoration(
        color: w.selected
            ? scheme.primary.withValues(alpha: 0.16)
            : hover
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(child: icon),
    );
    final item = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        onTap: w.onTap,
        onHover: (h) => setState(() => _hover = h),
        hoverColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.only(left: _railInset, right: 16),
          child: Row(
            children: [
              tile,
              const SizedBox(width: 14),
              Expanded(
                child: _FadeLabel(
                  visible: w.open,
                  child: Text(
                    w.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: labelColor,
                      fontWeight: w.selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (w.trailing != null)
                _FadeLabel(
                  visible: w.open,
                  child: Text(w.trailing!, style: theme.textTheme.labelMedium?.copyWith(color: Cinema.faint)),
                ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      label: w.label,
      selected: w.selected,
      button: w.onTap != null,
      excludeSemantics: true,
      child: item,
    );
  }
}

/// One catalog in the open pane: text only, lined up with the labels above.
class _CatalogItem extends StatefulWidget {
  const _CatalogItem({required this.label, required this.tooltip, required this.selected, required this.onTap});

  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CatalogItem> createState() => _CatalogItemState();
}

class _CatalogItemState extends State<_CatalogItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final w = widget;
    return Tooltip(
      message: w.tooltip,
      waitDuration: const Duration(milliseconds: 900),
      child: InkWell(
        onTap: w.onTap,
        onHover: (h) => setState(() => _hover = h),
        hoverColor: Colors.transparent,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              // A short accent bar marks the open catalog.
              SizedBox(
                width: _labelStart,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    margin: const EdgeInsets.only(right: 10),
                    width: 3,
                    height: w.selected ? 18 : 0,
                    decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  w.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: w.selected || _hover ? Colors.white : Cinema.muted,
                    fontWeight: w.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
        ),
      ),
    );
  }
}

// --- main area --------------------------------------------------------------

class _Content extends StatelessWidget {
  const _Content({
    required this.page,
    required this.catalog,
    required this.rows,
    required this.seed,
    required this.inset,
    required this.onRetry,
    required this.onRefresh,
    required this.onSeeAll,
    required this.onBack,
  });

  /// The width the floating rail covers on the left.
  final double inset;
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
        _HomePage() => _HomeFeed(
          rows: rows,
          seed: seed,
          inset: inset,
          onRetry: onRetry,
          onRefresh: onRefresh,
          onSeeAll: onSeeAll,
        ),
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
    final banners = <Widget>[
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
    ];
    return Column(
      children: [
        for (final b in banners)
          Padding(
            padding: EdgeInsets.only(left: inset),
            child: b,
          ),
        // Home runs its hero under the rail; every other page keeps clear.
        Expanded(
          child: page is _HomePage && catalog != null
              ? body
              : Padding(
                  padding: EdgeInsets.only(left: inset),
                  child: body,
                ),
        ),
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
    required this.inset,
    required this.onRetry,
    required this.onRefresh,
    required this.onSeeAll,
  });

  final AsyncSnapshot<List<HomeRow>> rows;
  final int seed;

  /// The width the floating rail covers on the left.
  final double inset;
  final Future<void> Function() onRetry;
  final Future<void> Function() onRefresh;
  final ValueChanged<HomeRow> onSeeAll;

  @override
  Widget build(BuildContext context) {
    Widget clear(Widget child) => Padding(
      padding: EdgeInsets.only(left: inset),
      child: child,
    );
    if (rows.connectionState != ConnectionState.done) return clear(const Center(child: CircularProgressIndicator()));
    if (rows.hasError) {
      return clear(MessageView(icon: Icons.cloud_off, message: errorText(rows.error!), onRetry: onRetry));
    }
    final list = rows.data!;
    if (list.isEmpty) {
      return clear(
        MessageView(
          icon: Icons.movie_outlined,
          message:
              "Nothing to show yet. If your admin has added movies or shows, they may not be shared with "
              'your account: ask them to run "Check catalog" on your user in the Hub.',
          onRetry: onRetry,
        ),
      );
    }
    // The featured titles: a few with a backdrop, picked at random per load.
    final seen = <String>{};
    final withArt = [
      for (final r in list)
        for (final m in r.items)
          if (m.background != null && seen.add(m.id)) m,
    ]..shuffle(Random(seed));
    final featured = withArt.take(_heroCount).toList();
    final continuing = context.watch<ProgressStore>().continueWatching;
    final saved = context.watch<Watchlist>().items;
    final poster = posterWidthOf(context);

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          if (featured.isNotEmpty) _Hero(items: featured, inset: inset) else const SizedBox(height: 28),
          if (continuing.isNotEmpty)
            _Shelf(
              title: 'Continue watching',
              inset: inset,
              itemCount: continuing.length,
              itemWidth: poster * 1.9,
              height: poster * 1.9 * 9 / 16 + 30,
              itemBuilder: (context, i, width) {
                final p = continuing[i];
                return LandscapeCard(meta: p.meta, width: width, progress: p.fraction, subtitle: p.videoTitle);
              },
            ),
          if (saved.isNotEmpty)
            _Shelf(
              title: 'My list',
              inset: inset,
              itemCount: saved.length,
              itemWidth: poster,
              height: poster / posterAspect,
              itemBuilder: (context, i, width) => PosterCard(meta: saved[i], width: width),
            ),
          for (final row in list)
            _Shelf(
              title: row.title,
              inset: inset,
              onSeeAll: () => onSeeAll(row),
              itemCount: row.items.length,
              itemWidth: poster,
              height: poster / posterAspect,
              itemBuilder: (context, i, width) => PosterCard(meta: row.items[i], width: width),
            ),
        ],
      ),
    );
  }
}

/// How many titles the hero rotates through, and how long each stays.
const _heroCount = 6;
const _heroDwell = Duration(seconds: 9);

/// The top of home: a few featured titles, one at a time, cross-fading on
/// their own. Hovering holds the current one; the bars at the bottom right
/// show the time left and pick a title.
class _Hero extends StatefulWidget {
  const _Hero({required this.items, required this.inset});

  final List<StremioMeta> items;
  final double inset;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(vsync: this, duration: _heroDwell)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _show(_index + 1);
    });
  int _index = 0;
  bool _hover = false;

  bool get _rotates => widget.items.length > 1 && !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rotates && !_hover && !_clock.isAnimating) unawaited(_clock.forward());
    if (!_rotates) _clock.stop();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _show(int i) {
    setState(() => _index = i % widget.items.length);
    _clock.value = 0;
    if (_rotates && !_hover) unawaited(_clock.forward());
  }

  void _setHover(bool hover) {
    _hover = hover;
    if (hover) {
      _clock.stop();
      // Its Play and Details are the likeliest clicks: have the tracks ready.
      prefetchTracks(context, widget.items[_index]);
    } else if (_rotates) {
      unawaited(_clock.forward());
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = (size.height * 0.66).clamp(360.0, 700.0);
    final item = widget.items[_index];
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 900),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: _Billboard(key: ValueKey(item.id), item: item, inset: widget.inset),
            ),
            if (widget.items.length > 1)
              Positioned(
                right: pageGutter(context),
                bottom: 44,
                child: _HeroBars(count: widget.items.length, index: _index, clock: _clock, onPick: _show),
              ),
          ],
        ),
      ),
    );
  }
}

/// One bar per featured title; the current one fills as its time runs.
class _HeroBars extends StatelessWidget {
  const _HeroBars({required this.count, required this.index, required this.clock, required this.onPick});

  final int count;
  final int index;
  final Animation<double> clock;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          Semantics(
            button: true,
            selected: i == index,
            label: 'Featured title ${i + 1} of $count',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    width: i == index ? 40 : 16,
                    height: 4,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: i == index
                        ? AnimatedBuilder(
                            animation: clock,
                            builder: (_, _) => FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: clock.isAnimating || clock.value > 0 ? clock.value : 1,
                              child: const ColoredBox(color: Colors.white),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A big backdrop of one title with its logo, a few facts, the description,
/// and Play, Details and Watch together.
class _Billboard extends StatefulWidget {
  const _Billboard({super.key, required this.item, required this.inset});

  final StremioMeta item;
  final double inset;

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
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final gutter = pageGutter(context);
    final theme = Theme.of(context);
    final bg = theme.colorScheme.surface;
    final accent = theme.colorScheme.primary;
    return FutureBuilder<StremioMeta?>(
      future: _full,
      builder: (context, snap) {
        final meta = snap.data ?? widget.item;
        final title = Text(
          meta.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (size.width >= 1100 ? theme.textTheme.displayMedium : theme.textTheme.displaySmall)?.copyWith(
            color: Colors.white,
            height: 1.02,
            shadows: const [Shadow(blurRadius: 16, color: Colors.black54)],
          ),
        );
        final year = meta.releaseInfo ?? meta.year?.toString();
        final factStyle = theme.textTheme.titleSmall?.copyWith(color: Colors.white.withValues(alpha: 0.92));
        final facts = <Widget>[
          if (meta.imdbRating != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.22),
                border: Border.all(color: accent.withValues(alpha: 0.55)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_rounded, size: 16, color: accent),
                  const SizedBox(width: 4),
                  Text(meta.imdbRating!.toStringAsFixed(1), style: factStyle?.copyWith(color: Colors.white)),
                ],
              ),
            ),
          if (year != null) Text(year, style: factStyle),
          if (meta.runtime != null) Text(meta.runtime!, style: factStyle),
          if (meta.genres.isNotEmpty)
            Text(meta.genres.take(3).join(', '), style: factStyle?.copyWith(color: Cinema.muted)),
        ];
        final textLeft = widget.inset + gutter;
        return Stack(
          fit: StackFit.expand,
          children: [
            NetImage(meta.background, alignment: Alignment.topCenter),
            // A night wash from the left for the text, and a fade into the
            // page at the bottom.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0, 0.38, 0.75],
                  colors: [bg.withValues(alpha: 0.94), bg.withValues(alpha: 0.55), Colors.transparent],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.18, 0.6, 1],
                  colors: [bg.withValues(alpha: 0.35), Colors.transparent, Colors.transparent, bg],
                ),
              ),
            ),
            Positioned(
              left: textLeft,
              bottom: 56,
              width: min(600, (size.width - textLeft) * 0.62),
              child: TweenAnimationBuilder<double>(
                // Each new title's text settles in as its picture fades up.
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (meta.logo != null)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 140, maxWidth: 460),
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
                      const SizedBox(height: 16),
                      Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: facts),
                    ],
                    if (meta.description != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        meta.description!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.white.withValues(alpha: 0.86),
                          height: 1.45,
                          shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        PlayButton(onPressed: () => _play(context, meta)),
                        _GlassButton(
                          icon: Icons.info_outline_rounded,
                          label: 'Details',
                          onPressed: () => openDetails(context, meta),
                        ),
                        _GlassButton(
                          icon: Icons.groups_rounded,
                          label: 'Watch together',
                          onPressed: () => showWatchTogetherSheet(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
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

/// A frosted secondary button for over artwork.
class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 22),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: Colors.white.withValues(alpha: 0.16),
      foregroundColor: Colors.white,
      side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
      minimumSize: const Size(0, 50),
      padding: const EdgeInsets.fromLTRB(18, 0, 22, 0),
      textStyle: Theme.of(context).textTheme.titleMedium,
    ),
  );
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
      foregroundColor: Cinema.background,
      minimumSize: const Size(0, 50),
      padding: const EdgeInsets.fromLTRB(18, 0, 26, 0),
      textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

/// A titled row that scrolls sideways, with round arrows at the ends under
/// the mouse (a mouse wheel can't scroll it).
class _Shelf extends StatefulWidget {
  const _Shelf({
    required this.title,
    required this.inset,
    required this.itemCount,
    required this.itemWidth,
    required this.height,
    required this.itemBuilder,
    this.onSeeAll,
  });

  final String title;
  final double inset;
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
    final left = widget.inset + gutter;
    // Room for the hover zoom and its shadow.
    const bleed = 14.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(left, 22, gutter, 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(fontSize: 22),
                  ),
                ),
                if (widget.onSeeAll != null) ...[
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: widget.onSeeAll,
                    style: TextButton.styleFrom(
                      foregroundColor: _hover ? theme.colorScheme.primary : Cinema.faint,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [Text('See all'), Icon(Icons.chevron_right_rounded, size: 18)],
                    ),
                  ),
                ],
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
                  padding: EdgeInsets.fromLTRB(left, bleed, gutter, bleed),
                  itemCount: widget.itemCount,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) => widget.itemBuilder(context, i, widget.itemWidth),
                ),
                if (!_atStart) _arrow(left: true, inset: widget.inset + 8, top: bleed),
                if (!_atEnd) _arrow(left: false, inset: 8, top: bleed),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrow({required bool left, required double inset, required double top}) {
    return Positioned(
      left: left ? inset : null,
      right: left ? null : inset,
      top: top,
      bottom: top,
      child: Center(
        child: AnimatedOpacity(
          opacity: _hover ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !_hover,
            child: Material(
              color: Cinema.background.withValues(alpha: 0.78),
              shape: CircleBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.2))),
              clipBehavior: Clip.antiAlias,
              elevation: 6,
              shadowColor: Colors.black,
              child: InkWell(
                onTap: () => _page(left ? -1 : 1),
                child: SizedBox.square(
                  dimension: 46,
                  child: Icon(
                    left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                    size: 30,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
