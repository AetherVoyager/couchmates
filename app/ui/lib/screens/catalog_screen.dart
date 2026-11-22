import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme.dart';
import '../widgets/poster.dart';

/// One catalog as a grid, loading more as you scroll, with a genre filter
/// when the catalog has one. Shown inside the home screen's side pane layout.
class CatalogView extends StatefulWidget {
  const CatalogView({super.key, required this.catalog, required this.title, this.subtitle, this.onBack});

  final StremioCatalog catalog;
  final String title;
  final String? subtitle;

  /// Shows a back arrow before the title.
  final VoidCallback? onBack;

  @override
  State<CatalogView> createState() => _CatalogViewState();
}

class _CatalogViewState extends State<CatalogView> {
  final _scroll = ScrollController();
  late CatalogPager _pager;
  String? _genre;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reset();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _more();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reset() {
    final client = context.read<HubSession>().catalog!;
    _pager = CatalogPager(client, widget.catalog, genre: _genre);
    _error = null;
    _more();
  }

  Future<void> _more() async {
    if (_loading || _pager.done) return;
    setState(() => _loading = true);
    final pager = _pager;
    try {
      await pager.loadMore();
      // Fill a tall window: keep going while there's no scrollbar yet.
      if (mounted &&
          identical(pager, _pager) &&
          !pager.done &&
          (_scroll.hasClients && _scroll.position.maxScrollExtent == 0)) {
        _loading = false;
        await _more();
        return;
      }
    } catch (e) {
      if (identical(pager, _pager)) _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final genres = widget.catalog.genres;
    final gutter = pageGutter(context);
    final theme = Theme.of(context);
    final header = Padding(
      padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (widget.onBack != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: IconButton(
                tooltip: 'Back',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back_rounded),
                style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary, letterSpacing: 1.4),
                  ),
                Text(widget.title, style: theme.textTheme.headlineMedium),
              ],
            ),
          ),
          if (genres.isNotEmpty)
            PopupMenuButton<String?>(
              tooltip: 'Genre',
              initialValue: _genre,
              onSelected: (g) => setState(() {
                _genre = g;
                _reset();
              }),
              itemBuilder: (_) => [
                const PopupMenuItem(value: null, child: Text('All genres')),
                for (final g in genres) PopupMenuItem(value: g, child: Text(g)),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white54),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.black,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_genre ?? 'Genres', style: theme.textTheme.labelLarge),
                    const SizedBox(width: 6),
                    const Icon(Icons.arrow_drop_down, size: 20),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (_pager.items.isEmpty && _error != null) {
      return Column(
        children: [
          header,
          Expanded(
            child: MessageView(icon: Icons.cloud_off, message: errorText(_error!), onRetry: () => setState(_reset)),
          ),
        ],
      );
    }
    if (_pager.items.isEmpty && !_loading) {
      return Column(
        children: [
          header,
          const Expanded(
            child: MessageView(icon: Icons.movie_outlined, message: 'Nothing here.'),
          ),
        ],
      );
    }
    return PosterGrid(
      items: _pager.items,
      controller: _scroll,
      header: header,
      padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 16),
      footer: _loading
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          : const SizedBox(height: 24),
    );
  }
}

/// [CatalogView] as a page of its own.
class CatalogScreen extends StatelessWidget {
  const CatalogScreen({super.key, required this.catalog, required this.title});

  final StremioCatalog catalog;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: CatalogView(catalog: catalog, title: title),
  );
}
