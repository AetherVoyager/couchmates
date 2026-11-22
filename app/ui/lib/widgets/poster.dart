import 'dart:async';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/details_screen.dart';
import '../screens/media_tracks.dart';

/// Poster width for the Appearance setting.
double posterWidthOf(BuildContext context) => switch (context.watch<AppSettings>().posterSize) {
  PosterSize.small => 120,
  PosterSize.medium => 150,
  PosterSize.large => 190,
};
const posterAspect = 2 / 3;

/// A network image that shows [fallback] while loading or when it fails.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.fallback, this.alignment = Alignment.center});

  final String? url;
  final BoxFit fit;
  final Widget? fallback;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final placeholder = fallback ?? ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
    final u = url;
    if (u == null || !(u.startsWith('http://') || u.startsWith('https://'))) return placeholder;
    return Image.network(
      u,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
      frameBuilder: (_, child, frame, wasSync) => wasSync || frame != null ? child : placeholder,
    );
  }
}

void openDetails(BuildContext context, StremioMeta meta) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DetailsScreen(item: meta)));

/// Grows a little under the mouse or keyboard focus, like a streaming app's
/// tiles.
class HoverZoom extends StatefulWidget {
  const HoverZoom({
    super.key,
    required this.builder,
    required this.onTap,
    this.tooltip,
    this.scale = 1.06,
    this.onDwell,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback onTap;

  /// Called once the pointer has rested on it for a moment.
  final VoidCallback? onDwell;
  final String? tooltip;
  final double scale;

  @override
  State<HoverZoom> createState() => _HoverZoomState();
}

class _HoverZoomState extends State<HoverZoom> {
  bool _hover = false;
  Timer? _dwell;

  void _set(bool h) {
    setState(() => _hover = h);
    _dwell?.cancel();
    if (h && widget.onDwell != null) _dwell = Timer(const Duration(milliseconds: 350), widget.onDwell!);
  }

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = InkWell(
      onTap: widget.onTap,
      onHover: _set,
      onFocusChange: _set,
      borderRadius: BorderRadius.circular(6),
      hoverColor: Colors.transparent,
      splashColor: Colors.white10,
      child: AnimatedScale(
        scale: _hover ? widget.scale : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: widget.builder(context, _hover),
      ),
    );
    if (widget.tooltip != null) child = Tooltip(message: widget.tooltip!, child: child);
    return child;
  }
}

/// A title's poster; opens the details. [caption] adds the name and year
/// underneath, for grids.
class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.meta, this.width, this.progress, this.caption = false});

  final StremioMeta meta;

  /// Null: the Appearance poster size.
  final double? width;

  /// Watched fraction, drawn as a bar on the poster.
  final double? progress;
  final bool caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final art = HoverZoom(
      tooltip: caption ? null : meta.name,
      onTap: () => openDetails(context, meta),
      onDwell: () => prefetchTracks(context, meta),
      builder: (context, hovered) => AspectRatio(
        aspectRatio: posterAspect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            boxShadow: hovered
                ? const [BoxShadow(color: Colors.black, blurRadius: 18, offset: Offset(0, 8))]
                : const [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetImage(
                  meta.poster,
                  fallback: Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(10),
                    child: Text(meta.name, textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
                  ),
                ),
                if (progress != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: Colors.white24,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return SizedBox(
      width: width ?? posterWidthOf(context),
      child: caption
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                art,
                const SizedBox(height: 8),
                Text(meta.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                if (meta.year != null)
                  Text(
                    '${meta.year}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            )
          : art,
    );
  }
}

/// A wide card with the title's backdrop, for Continue watching.
class LandscapeCard extends StatelessWidget {
  const LandscapeCard({super.key, required this.meta, required this.width, this.subtitle, this.progress, this.onTap});

  final StremioMeta meta;
  final double width;
  final String? subtitle;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: HoverZoom(
        onTap: onTap ?? () => openDetails(context, meta),
        builder: (context, hovered) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NetImage(meta.background ?? meta.poster, alignment: Alignment.topCenter),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0.4, 1],
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                    ),
                    Center(
                      child: AnimatedOpacity(
                        opacity: hovered ? 1 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black45,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          padding: const EdgeInsets.all(6),
                          child: const Icon(Icons.play_arrow_rounded, size: 32, color: Colors.white),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Text(
                        meta.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
                      ),
                    ),
                    if (progress != null)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: Colors.white24,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A grid of posters that fills the width, with an optional [header] above.
class PosterGrid extends StatelessWidget {
  const PosterGrid({super.key, required this.items, this.controller, this.footer, this.header, this.padding});

  final List<StremioMeta> items;
  final ScrollController? controller;
  final Widget? footer;
  final Widget? header;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: controller,
      slivers: [
        if (header != null) SliverToBoxAdapter(child: header),
        SliverPadding(
          padding: padding ?? const EdgeInsets.all(16),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: posterWidthOf(context) + 24,
              mainAxisSpacing: 24,
              crossAxisSpacing: 14,
              childAspectRatio: posterAspect * 0.82,
            ),
            itemCount: items.length,
            itemBuilder: (_, i) => PosterCard(meta: items[i], width: double.infinity, caption: true),
          ),
        ),
        if (footer != null) SliverToBoxAdapter(child: footer),
      ],
    );
  }
}

/// A message with an optional retry button, for empty and failed screens.
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.icon, required this.message, this.onRetry});

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String errorText(Object e) => switch (e) {
  StremioException(:final message) => message,
  HubException(:final message) => message,
  _ => 'Something went wrong.',
};
