import 'dart:async';
import 'dart:math';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../watch_together/watch_together_sheet.dart';
import '../widgets/poster.dart';
import 'details_extras.dart';
import 'home_screen.dart' show PlayButton;
import 'media_tracks.dart';
import 'play.dart';

/// A movie or a show: a big backdrop with the title logo, facts, actions,
/// the version, audio and subtitle pickers, and the description; then info,
/// cast, episodes and extras.
class DetailsScreen extends StatefulWidget {
  const DetailsScreen({super.key, required this.item});

  /// The catalog entry; the full details load from the catalog.
  final StremioMeta item;

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  late Future<StremioMeta?> _meta;
  Future<TitleInfo>? _info;
  String? _infoFor;
  int? _season;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _meta = context.read<HubSession>().catalog!.meta(widget.item.type, widget.item.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: Padding(
          padding: const EdgeInsets.all(6),
          child: IconButton.filled(
            tooltip: 'Back',
            style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
      body: FutureBuilder<StremioMeta?>(
        future: _meta,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return MessageView(icon: Icons.cloud_off, message: errorText(snap.error!), onRetry: () => setState(_load));
          }
          // Fall back to the catalog entry if the server has no details.
          final meta = snap.data ?? widget.item;
          if (_infoFor != meta.id) {
            _infoFor = meta.id;
            _info = loadTitleInfo(context.read<HubSession>(), meta);
          }
          return FutureBuilder<TitleInfo>(
            future: _info,
            builder: (context, info) => _body(context, meta, info.data ?? const TitleInfo()),
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, StremioMeta meta, TitleInfo info) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width > 760;
    final gutter = pageGutter(context);
    final seasons = meta.seasons;
    final season = _season ?? (seasons.isEmpty ? null : seasons.first);
    final episodes = season == null ? const <StremioVideo>[] : meta.episodesOf(season);
    final bg = Theme.of(context).colorScheme.surface;
    final hasArt = meta.background != null;

    final header = _Header(meta: meta, info: info);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: hasArt ? (size.height * 0.72).clamp(420.0, 760.0) : 0),
            child: Stack(
              children: [
                if (hasArt) Positioned.fill(child: NetImage(meta.background, alignment: Alignment.topCenter)),
                if (hasArt)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: const [0, 0.5, 0.9],
                          colors: [bg, bg.withValues(alpha: 0.7), bg.withValues(alpha: 0.05)],
                        ),
                      ),
                    ),
                  ),
                if (hasArt)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, 0.25, 0.7, 1],
                          colors: [Colors.black54, Colors.transparent, Colors.transparent, bg],
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(gutter, kToolbarHeight + (hasArt ? 120 : 32), gutter, 16),
                  child: wide && !hasArt && meta.poster != null
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 220,
                              child: AspectRatio(
                                aspectRatio: posterAspect,
                                child: ClipRRect(borderRadius: BorderRadius.circular(6), child: NetImage(meta.poster)),
                              ),
                            ),
                            const SizedBox(width: 32),
                            Expanded(child: header),
                          ],
                        )
                      : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: header),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: InfoRows(meta: meta, info: info),
        ),
        SliverToBoxAdapter(child: CastRow(cast: info.cast)),
        if (season != null) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 8),
              child: Row(
                children: [
                  Text('Episodes', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(width: 20),
                  if (seasons.length > 1)
                    _SeasonPicker(seasons: seasons, season: season, onPicked: (s) => setState(() => _season = s))
                  else
                    Text(
                      season == 0 ? 'Specials' : 'Season $season',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Cinema.muted),
                    ),
                  const Spacer(),
                  _SeasonWatchedButton(meta: meta, episodes: episodes),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: episodes.length,
            itemBuilder: (context, i) => _EpisodeTile(meta: meta, video: episodes[i]),
          ),
        ],
        SliverToBoxAdapter(child: ExtrasRow(videos: info.videos)),
        const SliverToBoxAdapter(child: SizedBox(height: 48)),
      ],
    );
  }
}

class _SeasonPicker extends StatelessWidget {
  const _SeasonPicker({required this.seasons, required this.season, required this.onPicked});

  final List<int> seasons;
  final int season;
  final ValueChanged<int> onPicked;

  @override
  Widget build(BuildContext context) {
    String name(int s) => s == 0 ? 'Specials' : 'Season $s';
    return PopupMenuButton<int>(
      tooltip: 'Season',
      initialValue: season,
      onSelected: onPicked,
      itemBuilder: (_) => [for (final s in seasons) PopupMenuItem(value: s, child: Text(name(s)))],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF242424),
          border: Border.all(color: const Color(0xFF4D4D4D)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name(season), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

/// Title logo or name, facts, tagline, actions, media pickers and description.
class _Header extends StatefulWidget {
  const _Header({required this.meta, required this.info});

  final StremioMeta meta;
  final TitleInfo info;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  /// What the Play button plays and the tracks picked for it.
  MediaChoice _choice = const MediaChoice();

  StremioMeta get meta => widget.meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = context.watch<ProgressStore>();
    final info = widget.info;
    final title = Text(meta.name, style: theme.textTheme.displaySmall?.copyWith(color: Colors.white));

    // What the main button plays, and how far into it.
    final isShow = meta.isSeries && meta.videos.isNotEmpty;
    final video = isShow ? (continueEpisode(progress, meta) ?? meta.episodesOf(meta.seasons.first).firstOrNull) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The title's logo artwork when there is one.
        if (meta.logo != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140, maxWidth: 480),
            child: Image.network(
              meta.logo!,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              errorBuilder: (_, _, _) => title,
              semanticLabel: meta.name,
            ),
          )
        else
          title,
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (meta.releaseInfo != null) _Fact(meta.releaseInfo!),
            if (info.certification != null) _Fact(info.certification!, outlined: true),
            if (meta.runtime != null) _Fact(meta.runtime!),
            if (meta.imdbRating != null) _Fact('★ ${meta.imdbRating!.toStringAsFixed(1)}', strong: true),
            if (meta.genres.isNotEmpty) _Fact(meta.genres.take(3).join(' · ')),
          ],
        ),
        if (info.tagline != null) ...[
          const SizedBox(height: 12),
          Text(
            info.tagline!,
            style: theme.textTheme.titleMedium?.copyWith(fontStyle: FontStyle.italic, color: Cinema.muted),
          ),
        ],
        const SizedBox(height: 22),
        _Actions(meta: meta, info: info, video: video, choice: _choice),
        const SizedBox(height: 18),
        MediaPickers(
          key: ValueKey(video?.id ?? meta.id),
          meta: meta,
          video: video,
          onChanged: (c) => setState(() => _choice = c),
        ),
        if (meta.description != null) ...[
          const SizedBox(height: 18),
          Text(meta.description!, style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white, height: 1.45)),
        ],
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.text, {this.outlined = false, this.strong = false});

  final String text;
  final bool outlined;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleSmall?.copyWith(
      color: strong ? const Color(0xFF46D369) : Colors.white.withValues(alpha: 0.9),
      fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
    );
    if (!outlined) return Text(text, style: style);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white70),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: style),
    );
  }
}

/// Play or resume (with time left), trailer, My list, watched, shuffle and
/// watch together.
class _Actions extends StatelessWidget {
  const _Actions({required this.meta, required this.info, required this.video, required this.choice});

  final StremioMeta meta;
  final TitleInfo info;
  final StremioVideo? video;
  final MediaChoice choice;

  @override
  Widget build(BuildContext context) {
    final progress = context.watch<ProgressStore>();
    final list = context.watch<Watchlist>();
    final theme = Theme.of(context);
    final isShow = meta.isSeries && meta.videos.isNotEmpty;
    final v = video;

    final at = isShow ? (v == null ? null : progress.of(v.id)) : progress.of(meta.id);
    final resuming = at != null && at.resumable;
    final left = resuming ? Duration(milliseconds: at.durationMs - at.positionMs) : null;
    final episodeLabel = v != null && v.season != null && v.episode != null ? 'S${v.season} E${v.episode}' : null;
    final label = [resuming ? 'Resume' : 'Play', ?episodeLabel].join(' ');

    final watched = isShow
        ? meta.videos.isNotEmpty && meta.videos.every((v) => progress.isWatched(v.id))
        : progress.isWatched(meta.id);
    final trailer = info.videos.firstOrNull;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PlayButton(
          label: label,
          onPressed: () => playTitle(
            context,
            meta: meta,
            video: v,
            stream: choice.stream,
            audioTrack: choice.audio,
            subtitleTrack: choice.subtitle,
          ),
        ),
        if (resuming)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  value: at.fraction,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Text('${_minutes(left!)} left', style: theme.textTheme.bodyMedium?.copyWith(color: Cinema.muted)),
            ],
          ),
        if (trailer != null)
          _ActionButton(
            icon: Icons.theaters_rounded,
            tooltip: 'Trailer',
            onPressed: () => launchUrl(trailer.url, mode: LaunchMode.externalApplication),
          ),
        _ActionButton(
          icon: list.contains(meta.id) ? Icons.check_rounded : Icons.add_rounded,
          tooltip: list.contains(meta.id) ? 'Remove from My list' : 'Add to My list',
          onPressed: () => list.toggle(meta),
        ),
        _ActionButton(
          icon: watched ? Icons.visibility_rounded : Icons.visibility_outlined,
          tooltip: watched ? 'Mark as not watched' : 'Mark as watched',
          selected: watched,
          onPressed: () => isShow
              ? progress.setManyWatched(meta, meta.videos, watched: !watched)
              : progress.setWatched(meta, watched: !watched),
        ),
        if (isShow)
          _ActionButton(
            icon: Icons.shuffle_rounded,
            tooltip: 'Play a random episode',
            onPressed: () {
              final pick = meta.videos[Random().nextInt(meta.videos.length)];
              unawaited(playTitle(context, meta: meta, video: pick));
            },
          ),
        _ActionButton(
          icon: Icons.groups_rounded,
          tooltip: 'Watch together',
          onPressed: () => showWatchTogetherSheet(context),
        ),
        if (theme.platform == TargetPlatform.windows && meta.id.startsWith('tt'))
          _ActionButton(
            icon: Icons.open_in_new_rounded,
            tooltip: 'Open on IMDb',
            onPressed: () => launchUrl(Uri.parse('https://www.imdb.com/title/${meta.id}/')),
          ),
      ],
    );
  }
}

String _minutes(Duration d) =>
    d.inMinutes >= 60 ? '${d.inHours} h ${d.inMinutes.remainder(60)} min' : '${max(1, d.inMinutes)} min';

/// A round outlined icon button over the artwork.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.tooltip, required this.onPressed, this.selected = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton.outlined(
    tooltip: tooltip,
    iconSize: 24,
    style: IconButton.styleFrom(
      minimumSize: const Size(46, 46),
      backgroundColor: selected ? Colors.white : Colors.black.withValues(alpha: 0.35),
      foregroundColor: selected ? Colors.black : Colors.white,
      side: const BorderSide(color: Colors.white70, width: 2),
    ),
    icon: Icon(icon),
    onPressed: onPressed,
  );
}

class _SeasonWatchedButton extends StatelessWidget {
  const _SeasonWatchedButton({required this.meta, required this.episodes});

  final StremioMeta meta;
  final List<StremioVideo> episodes;

  @override
  Widget build(BuildContext context) {
    final progress = context.watch<ProgressStore>();
    if (episodes.isEmpty) return const SizedBox.shrink();
    final all = episodes.every((e) => progress.isWatched(e.id));
    return TextButton.icon(
      onPressed: () => progress.setManyWatched(meta, episodes, watched: !all),
      style: TextButton.styleFrom(foregroundColor: Cinema.muted),
      icon: Icon(all ? Icons.remove_done_rounded : Icons.done_all_rounded),
      label: Text(all ? 'Mark season not watched' : 'Mark season watched'),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.meta, required this.video});

  final StremioMeta meta;
  final StremioVideo video;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = context.watch<ProgressStore>();
    final p = progress.of(video.id);
    final watched = p?.finished ?? false;
    final released = video.released;
    final upcoming = released != null && released.isAfter(DateTime.now());
    final gutter = pageGutter(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: gutter - 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => playTitle(context, meta: meta, video: video),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!narrow)
                SizedBox(
                  width: 48,
                  child: Text(
                    '${video.episode ?? ''}',
                    style: theme.textTheme.headlineSmall?.copyWith(color: Cinema.muted),
                  ),
                ),
              SizedBox(
                width: narrow ? 140 : 200,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NetImage(video.thumbnail ?? meta.background),
                        const Center(child: Icon(Icons.play_circle_outline, size: 40, color: Colors.white70)),
                        if (watched)
                          const Positioned(
                            top: 6,
                            right: 6,
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: Colors.black54,
                              child: Icon(Icons.check, size: 16, color: Colors.white),
                            ),
                          ),
                        if (p != null && p.resumable)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: LinearProgressIndicator(
                              value: p.fraction,
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
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      narrow && video.episode != null ? '${video.episode}. ${video.title}' : video.title,
                      style: theme.textTheme.titleMedium?.copyWith(color: watched ? Cinema.muted : Colors.white),
                    ),
                    if (released != null)
                      Text(
                        upcoming ? 'Coming ${_date(released)}' : _date(released),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: upcoming ? theme.colorScheme.primary : Cinema.faint,
                        ),
                      ),
                    if (video.overview != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        video.overview!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: Cinema.muted),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: watched ? 'Mark as not watched' : 'Mark as watched',
                color: Cinema.muted,
                icon: Icon(watched ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded),
                onPressed: () => progress.setWatched(meta, video: video, watched: !watched),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// The episode to continue a show with: the one in progress, or the one
/// after the last finished episode. Null if nothing was watched.
StremioVideo? continueEpisode(ProgressStore progress, StremioMeta meta) {
  final last = progress.latestFor(meta.id);
  final id = last?.videoId;
  if (last == null || id == null) return null;
  if (!last.finished) return meta.videos.where((v) => v.id == id).firstOrNull;
  return meta.nextAfter(id);
}
