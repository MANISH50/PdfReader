import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// Human-friendly file size: "820 KB", "12.4 MB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 || i == 0 ? v.round() : v.toStringAsFixed(1)} ${units[i]}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Relative day label: "Just now", "Today", "Yesterday", "3 days ago", "12 Mar 2026".
String formatLastOpened(DateTime when, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final diff = n.difference(when);
  if (diff.inMinutes < 1 && !diff.isNegative) return 'Just now';
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(when.year, when.month, when.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days days ago';
  return '${when.day} ${_months[when.month - 1]} ${when.year}';
}

/// Data shown by [DocumentTile] / [DocumentCard].
class DocumentTileData {
  const DocumentTileData({
    required this.id,
    required this.name,
    required this.sizeBytes,
    this.lastOpened,
    this.page,
    this.pageCount,
  });

  final String id;
  final String name;
  final int sizeBytes;
  final DateTime? lastOpened;

  /// Last read page (1-based), if known.
  final int? page;

  /// Total pages, if known (enables the progress bar).
  final int? pageCount;

  double? get progress =>
      page != null && pageCount != null && pageCount! > 0 ? (page! / pageCount!).clamp(0.0, 1.0) : null;

  String get pageLabel => page == null
      ? ''
      : pageCount == null
      ? 'Page $page'
      : 'Page $page of $pageCount';

  String get metaLine => [formatBytes(sizeBytes), if (lastOpened != null) formatLastOpened(lastOpened!)].join(' · ');

  String get semanticsLabel => [name, metaLine, if (page != null) pageLabel].join(', ');
}

/// Thumbnail placeholder: a tinted paper sheet with a folded corner and a
/// "PDF" badge; colour is derived from the document id so each file keeps a
/// stable look. Pass [thumbnail] to show a rendered first page instead.
class DocumentThumb extends StatelessWidget {
  const DocumentThumb({super.key, required this.id, this.thumbnail, this.width = 48});
  final String id;
  final Widget? thumbnail;
  final double width;

  static const _hues = [228.0, 200.0, 262.0, 170.0, 20.0, 330.0];

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final dark = s.brightness == Brightness.dark;
    final hue = _hues[id.hashCode.abs() % _hues.length];
    final tint = HSLColor.fromAHSL(1, hue, 0.55, dark ? 0.32 : 0.9).toColor();
    final ink = HSLColor.fromAHSL(1, hue, 0.5, dark ? 0.8 : 0.4).toColor();
    return Hero(
      tag: 'doc-thumb-$id',
      child: SizedBox(
        width: width,
        height: width * 1.3,
        child: ClipRRect(
          borderRadius: Radii.tile,
          child:
              thumbnail ??
              DecoratedBox(
                decoration: BoxDecoration(color: tint),
                child: LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth;
                    return Stack(
                      children: [
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            width: w * 0.28,
                            height: w * 0.28,
                            decoration: BoxDecoration(
                              color: ink.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.only(bottomLeft: Radius.circular(w * 0.08)),
                            ),
                          ),
                        ),
                        for (var i = 0; i < 3; i++)
                          Positioned(
                            left: w * 0.18,
                            right: w * (i == 2 ? 0.45 : 0.22),
                            top: w * (0.42 + i * 0.16),
                            child: Container(
                              height: (w * 0.06).clamp(2, 8),
                              decoration: BoxDecoration(color: ink.withValues(alpha: 0.35), borderRadius: Radii.pill),
                            ),
                          ),
                        Positioned(
                          left: w * 0.12,
                          bottom: w * 0.1,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: w * 0.06, vertical: w * 0.02),
                            decoration: BoxDecoration(color: ink, borderRadius: Radii.pill),
                            child: Text(
                              'PDF',
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                color: tint,
                                fontSize: (w * 0.16).clamp(7, 20),
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
        ),
      ),
    );
  }
}

/// List row for a document: thumbnail, name, size · last opened, page
/// progress. Used on phones.
class DocumentTile extends StatelessWidget {
  const DocumentTile({
    super.key,
    required this.data,
    required this.onTap,
    this.trailing,
    this.thumbnail,
    this.semanticHint = 'Opens the document',
  });

  final DocumentTileData data;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? thumbnail;
  final String semanticHint;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: Radii.card,
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Semantics(
                button: true,
                label: data.semanticsLabel,
                hint: semanticHint,
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm + 2),
                  child: Row(
                    children: [
                      DocumentThumb(id: data.id, thumbnail: thumbnail, width: 48),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              data.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.titleMedium,
                            ),
                            const SizedBox(height: Space.xxs),
                            Text(
                              data.metaLine,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
                            ),
                            if (data.page != null) ...[const SizedBox(height: Space.xs + 2), _Progress(data: data)],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Grid card for a document. Used on tablets / wide windows.
class DocumentCard extends StatelessWidget {
  const DocumentCard({
    super.key,
    required this.data,
    required this.onTap,
    this.trailing,
    this.thumbnail,
    this.semanticHint = 'Opens the document',
  });

  final DocumentTileData data;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? thumbnail;
  final String semanticHint;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Semantics(
              button: true,
              label: data.semanticsLabel,
              hint: semanticHint,
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.all(Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, c) => Center(
                          child: DocumentThumb(
                            id: data.id,
                            thumbnail: thumbnail,
                            width: (c.maxHeight / 1.3).clamp(0, 120).toDouble(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Text(data.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                    Text(
                      data.metaLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
                    ),
                    const SizedBox(height: Space.xs),
                    SizedBox(height: 4, child: data.progress != null ? _Bar(value: data.progress!) : null),
                  ],
                ),
              ),
            ),
            if (trailing != null) Positioned(top: 0, right: 0, child: trailing!),
          ],
        ),
      ),
    );
  }

  /// Height a card needs at the current text scale.
  static double extentFor(BuildContext context) {
    final sc = MediaQuery.textScalerOf(context);
    return 170 + sc.scale(20) + sc.scale(16) + Space.md * 2 + Space.sm + Space.xs + 4 + 8;
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.data});
  final DocumentTileData data;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final label = Text(
      data.pageLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
    );
    if (data.progress == null) return label;
    return Row(
      children: [
        Expanded(flex: 3, child: _Bar(value: data.progress!)),
        const SizedBox(width: Space.sm),
        Flexible(flex: 2, child: label),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value});
  final double value;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: Radii.pill,
    child: LinearProgressIndicator(
      value: value,
      minHeight: 4,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    ),
  );
}
