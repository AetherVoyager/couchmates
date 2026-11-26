import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'settings/setting_tiles.dart' show languageChoices, languageName;

/// The player's "Search subtitles": OpenSubtitles through the Hub (when it
/// has a key) plus the free add-on's list, in one language or all, and a
/// subtitle file from this computer. Picking one loads it straight away.
class SubtitleSearchPanel extends StatefulWidget {
  const SubtitleSearchPanel({
    super.key,
    required this.playable,
    required this.addon,
    required this.hash,
    required this.loaded,
    required this.onPick,
    required this.onOpenFile,
    required this.onClose,
  });

  final Playable playable;

  /// The add-on's list for this title, once it has arrived.
  final List<OnlineSubtitle>? addon;

  /// The file's OpenSubtitles hash, for exact matches; null when unknown.
  final Future<String?> hash;

  /// Keys of the choices already loaded.
  final Set<String> loaded;

  /// Loads [choice]; false when it failed (the player says why).
  final Future<bool> Function(SubtitleChoice choice) onPick;
  final Future<void> Function() onOpenFile;
  final VoidCallback onClose;

  @override
  State<SubtitleSearchPanel> createState() => _SubtitleSearchPanelState();
}

class _SubtitleSearchPanelState extends State<SubtitleSearchPanel> {
  late final TextEditingController _query;
  late final List<String> _preferred;

  /// Null for every language.
  String? _language;
  SubtitleSearch _hub = SubtitleSearch.none;
  bool _searching = false;
  String? _problem;
  String? _busy;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController();
    _preferred = onlineSubtitleLanguages(context.read<AppSettings>());
    _language = _preferred.first;
    unawaited(_search());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final gen = ++_generation;
    setState(() {
      _searching = true;
      _problem = null;
    });
    final session = context.read<HubSession>();
    SubtitleSearch hub = SubtitleSearch.none;
    String? problem;
    try {
      final hash = await widget.hash.timeout(const Duration(seconds: 15), onTimeout: () => null);
      final lang = _language;
      hub = await session.searchSubtitles(
        subtitleRequestFor(
          widget.playable,
          languages: lang == null ? const [] : [lang],
          query: _query.text,
          hash: hash,
        ),
      );
    } on HubException catch (e) {
      problem = e.message;
    } catch (_) {
      problem = "Couldn't search right now.";
    }
    if (!mounted || gen != _generation) return;
    setState(() {
      _hub = hub;
      _problem = problem;
      _searching = false;
    });
  }

  Future<void> _pick(SubtitleChoice c) async {
    if (_busy != null) return;
    setState(() => _busy = c.key);
    final ok = await widget.onPick(c);
    if (!mounted) return;
    setState(() => _busy = null);
    if (ok) widget.onClose();
  }

  List<(String?, String)> get _languages {
    final seen = <String>{};
    return [
      (null, 'All languages'),
      for (final code in [..._preferred, ...languageChoices.map((l) => l.$1)])
        if (seen.add(code)) (code, languageName(code)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The add-on's list is per title, so typed words only narrow the Hub's.
    final addon = _query.text.trim().isEmpty ? (widget.addon ?? const <OnlineSubtitle>[]) : const <OnlineSubtitle>[];
    final choices = subtitleChoices(hub: _hub, addon: addon, language: _language);
    final waiting = _searching || (widget.addon == null && _query.text.trim().isEmpty);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
      child: GestureDetector(
        // Taps inside don't reach the player behind.
        onTap: () {},
        child: Material(
          color: scheme.surfaceContainer.withValues(alpha: 0.96),
          elevation: 12,
          shadowColor: Colors.black,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: SizedBox(
            width: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 6, 0),
                  child: Row(
                    children: [
                      Icon(Icons.subtitles_outlined, color: scheme.primary, size: 20),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Search subtitles', style: theme.textTheme.titleMedium)),
                      IconButton(
                        tooltip: 'Close (Esc)',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _query,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _search(),
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: widget.playable.meta.name,
                            helperText: 'Leave empty to match this title',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          initialValue: _language,
                          isDense: true,
                          isExpanded: true,
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: 'Language',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          items: [
                            for (final (code, name) in _languages)
                              DropdownMenuItem(
                                value: code,
                                child: Text(name, overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: (v) {
                            setState(() => _language = v);
                            unawaited(_search());
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(onPressed: _searching ? null : _search, child: const Text('Search')),
                    ],
                  ),
                ),
                if (waiting) const LinearProgressIndicator(minHeight: 2) else const Divider(height: 2),
                Flexible(child: _results(context, choices, waiting)),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: widget.onOpenFile,
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('Load from a file'),
                      ),
                      Expanded(
                        child: Text(
                          'OpenSubtitles',
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _results(BuildContext context, List<SubtitleChoice> choices, bool waiting) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final notes = [
      if (_problem != null) _Note(icon: Icons.error_outline, text: _problem!, error: true),
      if (!_hub.available && !_searching && _problem == null)
        const _Note(
          icon: Icons.info_outline,
          text:
              'Showing the free add-on\'s list. For search by name and more results, the Hub admin can add an '
              'OpenSubtitles key in Hub Settings.',
        ),
    ];
    if (choices.isEmpty) {
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        children: [
          ...notes,
          if (!waiting)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _language == null
                    ? 'No subtitles found. Try other words.'
                    : 'No ${languageName(_language!)} subtitles found. Try All languages or other words.',
                style: muted,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      children: [
        if (notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(children: notes),
          ),
        for (final c in choices) _tile(context, c),
      ],
    );
  }

  Widget _tile(BuildContext context, SubtitleChoice c) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loaded = widget.loaded.contains(c.key);
    final busy = _busy == c.key;
    final tags = [
      if (c.hashMatch) ('Matches your file', scheme.primary),
      if (c.hearingImpaired) ('SDH', scheme.onSurfaceVariant),
      if (c.machineTranslated) ('Machine translated', scheme.tertiary),
      if (!c.fromHub) ('Add-on', scheme.onSurfaceVariant),
    ];
    final downloads = c.downloads;
    return ListTile(
      dense: true,
      enabled: !loaded && _busy == null,
      onTap: () => _pick(c),
      leading: Container(
        width: 40,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
        child: Text(
          c.language.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          maxLines: 1,
        ),
      ),
      title: Text(c.label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(languageName(c.language), style: theme.textTheme.bodySmall),
          if (downloads != null && downloads > 0)
            Text('· ${_count(downloads)} downloads', style: theme.textTheme.bodySmall),
          for (final (label, color) in tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: color.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
            ),
        ],
      ),
      trailing: busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : loaded
          ? Icon(Icons.check_circle, color: scheme.primary, size: 20)
          : const Icon(Icons.download_outlined, size: 20),
    );
  }
}

String _count(int n) => n >= 1000000
    ? '${(n / 1000000).toStringAsFixed(1)}M'
    : n >= 1000
    ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k'
    : '$n';

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.error = false});

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
