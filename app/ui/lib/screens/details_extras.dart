import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../widgets/poster.dart';

/// Everything about a title beyond the catalog entry: TMDB through the Hub
/// when it has a key, with gaps filled from the catalog and from Cinemeta
/// (Stremio's free metadata service).
class TitleInfo {
  const TitleInfo({
    this.cast = const [],
    this.directors = const [],
    this.writers = const [],
    this.tagline,
    this.certification,
    this.studios = const [],
    this.countries = const [],
    this.released,
    this.videos = const [],
  });

  final List<CastMember> cast;
  final List<String> directors;
  final List<String> writers;
  final String? tagline;
  final String? certification;
  final List<String> studios;
  final List<String> countries;
  final DateTime? released;
  final List<Extra> videos;
}

final _cinemeta = StremioClient(baseUrl: 'https://v3-cinemeta.strem.io');

Future<TitleInfo> loadTitleInfo(HubSession session, StremioMeta meta) async {
  final tmdb = await session.credits(meta);
  // Cinemeta fills what TMDB (or a missing key) leaves out.
  StremioMeta? cine;
  final needsMore = !tmdb.available || tmdb.cast.isEmpty || tmdb.videos.isEmpty;
  if (needsMore && meta.id.startsWith('tt')) {
    try {
      cine = await _cinemeta.meta(meta.type, meta.id);
    } catch (_) {}
  }
  List<T> pick<T>(List<T> a, List<T> b) => a.isNotEmpty ? a : b;
  final names = pick(meta.cast, cine?.cast ?? const <String>[]);
  final trailerIds = pick(meta.trailers, cine?.trailers ?? const <String>[]);
  return TitleInfo(
    cast: pick(tmdb.cast, [for (final n in names) CastMember(name: n)]),
    directors: pick(tmdb.directors, pick(meta.directors, cine?.directors ?? const <String>[])),
    writers: pick(tmdb.writers, pick(meta.writers, cine?.writers ?? const <String>[])),
    tagline: tmdb.tagline,
    certification: tmdb.certification,
    studios: tmdb.studios,
    countries: pick(tmdb.countries, [?(meta.country ?? cine?.country)]),
    released: DateTime.tryParse(tmdb.released ?? '') ?? meta.released ?? cine?.released,
    videos: pick(tmdb.videos, [for (final id in trailerIds) Extra(name: 'Trailer', kind: 'Trailer', youtube: id)]),
  );
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Director, writers, studio, country and release date, like Plezy's info rows.
class InfoRows extends StatelessWidget {
  const InfoRows({super.key, required this.meta, required this.info});

  final StremioMeta meta;
  final TitleInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = info.released;
    final rows = <(String, String)>[
      if (info.directors.isNotEmpty) (meta.isSeries ? 'Created by' : 'Director', info.directors.join(', ')),
      if (info.writers.isNotEmpty) ('Writers', info.writers.join(', ')),
      if (info.studios.isNotEmpty) (meta.isSeries ? 'Network' : 'Studio', info.studios.join(', ')),
      if (info.countries.isNotEmpty) ('Country', info.countries.join(', ')),
      if (r != null) (meta.isSeries ? 'First aired' : 'Released', '${r.day} ${_months[r.month - 1]} ${r.year}'),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxContentWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 40,
              runSpacing: 10,
              children: [
                for (final (label, value) in rows)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        Text(value, style: theme.textTheme.bodyLarge),
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
}

/// Trailers and featurettes; each opens on YouTube.
class ExtrasRow extends StatelessWidget {
  const ExtrasRow({super.key, required this.videos});

  final List<Extra> videos;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return _Section(
      title: 'Extras',
      child: SizedBox(
        height: 196,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: videos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, i) {
            final v = videos[i];
            return SizedBox(
              width: 240,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => launchUrl(v.url, mode: LaunchMode.externalApplication),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            NetImage(v.thumbnail),
                            const Center(child: Icon(Icons.play_circle_fill, size: 44, color: Colors.white70)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                    Text(v.kind, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The cast as a row of portraits with names and roles.
class CastRow extends StatelessWidget {
  const CastRow({super.key, required this.cast});

  final List<CastMember> cast;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return _Section(
      title: 'Cast',
      child: SizedBox(
        height: 178,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: cast.length,
          separatorBuilder: (_, _) => const SizedBox(width: 16),
          itemBuilder: (_, i) {
            final c = cast[i];
            final initials = c.name.split(' ').where((p) => p.isNotEmpty).take(2).map((p) => p[0]).join();
            return SizedBox(
              width: 104,
              child: Column(
                children: [
                  ClipOval(
                    child: SizedBox.square(
                      dimension: 96,
                      child: NetImage(
                        c.photo,
                        fallback: Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: Text(initials, style: theme.textTheme.titleLarge),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    c.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (c.character != null)
                    Text(
                      c.character!,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxContentWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            child,
          ],
        ),
      ),
    );
  }
}
