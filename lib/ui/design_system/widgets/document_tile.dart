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
    this.badge = 'PDF',
  });

  /// Short file-type label on the placeholder thumbnail (PDF, DOC, MD, TXT).
  final String badge;

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

/// Thumbnail placeholder: a sheet in the file type's colour (red PDF, blue
/// Word, green Excel…) with a folded corner, the type icon and its label.
/// Pass [thumbnail] to show a rendered first page instead.
class DocumentThumb extends StatelessWidget {
  const DocumentThumb({super.key, required this.id, this.thumbnail, this.width = 48, this.badge = 'PDF'});
  final String id;
  final String badge;
  final Widget? thumbnail;
  final double width;

  @override
  Widget build(BuildContext context) {
    final base = FileTypeStyle.color(badge);
    return Hero(
      tag: 'doc-thumb-$id',
      child: SizedBox(
        width: width,
        height: width * 1.3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(width * 0.2),
          child:
              thumbnail ??
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color.lerp(base, Colors.white, 0.22)!, base],
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth;
                    return Stack(
                      children: [
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            width: w * 0.3,
                            height: w * 0.3,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.28),
                              borderRadius: BorderRadius.only(bottomLeft: Radius.circular(w * 0.1)),
                            ),
                          ),
                        ),
                        Align(
                          alignment: const Alignment(0, -0.25),
                          child: Icon(FileTypeStyle.icon(badge), color: Colors.white, size: w * 0.46),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: w * 0.1,
                          child: Center(
                            child: Text(
                              badge,
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: (w * 0.2).clamp(7, 22),
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Space.xs + 1),
      decoration: BoxDecoration(
        color: s.surfaceContainerLow,
        borderRadius: const BorderRadius.all(Radius.circular(Radii.lg - 4)),
        border: Border.all(color: s.outlineVariant.withValues(alpha: 0.35)),
        boxShadow: softShadow(s, strength: 0.7),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: const BorderRadius.all(Radius.circular(Radii.lg - 4)),
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
                        DocumentThumb(id: data.id, thumbnail: thumbnail, width: 48, badge: data.badge),
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
                            badge: data.badge,
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
