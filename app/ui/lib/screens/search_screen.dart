import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme.dart';
import '../widgets/poster.dart';

/// A search box over the catalog with results as a poster grid.
class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _query = TextEditingController();
  Timer? _debounce;
  Future<List<StremioMeta>>? _results;
  String _searched = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(text));
  }

  void _search(String text) {
    final q = text.trim();
    if (q == _searched) return;
    setState(() {
      _searched = q;
      _results = q.length < 2 ? null : context.read<HubSession>().catalog!.search(q);
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
            hintText: 'Titles, people, genres',
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
      below = const MessageView(icon: Icons.search, message: 'Type a title to search.');
    } else {
      below = FutureBuilder<List<StremioMeta>>(
        future: _results,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return MessageView(icon: Icons.cloud_off, message: errorText(snap.error!));
          final items = snap.data!;
          if (items.isEmpty) return MessageView(icon: Icons.search_off, message: 'Nothing found for "$_searched".');
          return PosterGrid(items: items, padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 24));
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

/// [SearchView] as a page of its own.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(), body: const SearchView());
}
