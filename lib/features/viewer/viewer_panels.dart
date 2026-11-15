import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/security/limits.dart';
import '../../ui/design_system/tokens.dart';

/// Thumbnails grid. Pages render lazily as they scroll into view.
class ThumbnailsGrid extends StatelessWidget {
  const ThumbnailsGrid({
    super.key,
    required this.document,
    required this.currentPage,
    required this.bookmarks,
    required this.onSelect,
    this.colorFilter,
    this.scrollController,
  });

  final PdfDocument document;
  final int currentPage;
  final Set<int> bookmarks;
  final ValueChanged<int> onSelect;
  final ColorFilter? colorFilter;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = document.pages.length;
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(Space.md),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        childAspectRatio: 0.66,
        mainAxisSpacing: Space.md,
        crossAxisSpacing: Space.md,
      ),
      itemCount: count,
      itemBuilder: (context, i) {
        final n = i + 1;
        final selected = n == currentPage;
        Widget thumb = PdfPageView(document: document, pageNumber: n, maximumDpi: 48);
        if (colorFilter != null) thumb = ColorFiltered(colorFilter: colorFilter!, child: thumb);
        return Semantics(
          button: true,
          selected: selected,
          label: 'Page $n${bookmarks.contains(n) ? ', bookmarked' : ''}',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
            onTap: () => onSelect(n),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: selected ? scheme.primary : scheme.outlineVariant,
                        width: selected ? 3 : 1,
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        thumb,
                        if (bookmarks.contains(n))
                          Align(
                            alignment: Alignment.topRight,
                            child: Icon(Icons.bookmark, color: scheme.primary, size: 20),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.xs),
                Text('$n',
                    style: TextStyle(
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                        color: selected ? scheme.primary : null)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Loads the outline once (with a timeout) and shows nested nodes.
class OutlineList extends StatefulWidget {
  const OutlineList({super.key, required this.loadOutline, required this.onSelect, this.scrollController});

  final Future<List<PdfOutlineNode>> Function() loadOutline;
  final ValueChanged<PdfOutlineNode> onSelect;
  final ScrollController? scrollController;

  @override
  State<OutlineList> createState() => _OutlineListState();
}

class _OutlineListState extends State<OutlineList> {
  late final Future<List<PdfOutlineNode>> _future = () async {
    try {
      return await widget.loadOutline().timeout(SecurityLimits.pageTextTimeout);
    } catch (_) {
      return const <PdfOutlineNode>[];
    }
  }();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<PdfOutlineNode>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final nodes = snap.data!;
          if (nodes.isEmpty) {
            return const _EmptyPanel(icon: Icons.toc, text: 'This document has no table of contents.');
          }
          return ListView(
            controller: widget.scrollController,
            children: [for (final n in nodes) _node(n, 0)],
          );
        },
      );

  Widget _node(PdfOutlineNode n, int depth) {
    final title = n.title.trim().isEmpty ? 'Untitled' : n.title.trim();
    final page = n.dest?.pageNumber;
    final trailing = page == null ? null : Text('$page');
    final pad = EdgeInsets.only(left: Space.md + depth * Space.md, right: Space.md);
    // Guard against absurdly deep (malicious) outlines.
    if (n.children.isEmpty || depth >= 16) {
      return ListTile(
        contentPadding: pad,
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: trailing,
        enabled: n.dest != null,
        onTap: n.dest == null ? null : () => widget.onSelect(n),
      );
    }
    return ExpansionTile(
      tilePadding: pad,
      title: InkWell(
        onTap: n.dest == null ? null : () => widget.onSelect(n),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ),
      children: [for (final c in n.children) _node(c, depth + 1)],
    );
  }
}

class BookmarksList extends StatelessWidget {
  const BookmarksList({
    super.key,
    required this.bookmarks,
    required this.onSelect,
    required this.onRemove,
    this.scrollController,
  });

  final Set<int> bookmarks;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onRemove;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final sorted = bookmarks.toList()..sort();
    if (sorted.isEmpty) {
      return const _EmptyPanel(
        icon: Icons.bookmark_border,
        text: 'No bookmarks yet. Tap the bookmark button while reading to add one.',
      );
    }
    return ListView.builder(
      controller: scrollController,
      itemCount: sorted.length,
      itemBuilder: (context, i) => ListTile(
        leading: const Icon(Icons.bookmark),
        title: Text('Page ${sorted[i]}'),
        onTap: () => onSelect(sorted[i]),
        trailing: IconButton(
          tooltip: 'Remove bookmark for page ${sorted[i]}',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => onRemove(sorted[i]),
        ),
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: Space.md),
            Text(text, textAlign: TextAlign.center),
          ]),
        ),
      );
}

/// Tabbed navigation sheet: thumbnails, contents, bookmarks.
class NavigatorSheet extends StatelessWidget {
  const NavigatorSheet({
    super.key,
    required this.document,
    required this.currentPage,
    required this.bookmarks,
    required this.onPage,
    required this.onOutline,
    required this.onRemoveBookmark,
    this.colorFilter,
    this.initialTab = 0,
  });

  final PdfDocument document;
  final int currentPage;
  final Set<int> bookmarks;
  final ValueChanged<int> onPage;
  final ValueChanged<PdfOutlineNode> onOutline;
  final ValueChanged<int> onRemoveBookmark;
  final ColorFilter? colorFilter;
  final int initialTab;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        initialIndex: initialTab,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          builder: (context, scroll) => Column(
            children: [
              const TabBar(tabs: [
                Tab(icon: Icon(Icons.grid_view), text: 'Pages'),
                Tab(icon: Icon(Icons.toc), text: 'Contents'),
                Tab(icon: Icon(Icons.bookmarks_outlined), text: 'Bookmarks'),
              ]),
              Expanded(
                child: TabBarView(children: [
                  ThumbnailsGrid(
                    document: document,
                    currentPage: currentPage,
                    bookmarks: bookmarks,
                    onSelect: onPage,
                    colorFilter: colorFilter,
                    scrollController: scroll,
                  ),
                  OutlineList(loadOutline: document.loadOutline, onSelect: onOutline),
                  _BookmarksTab(initial: bookmarks, onSelect: onPage, onRemove: onRemoveBookmark),
                ]),
              ),
            ],
          ),
        ),
      );
}

class _BookmarksTab extends StatefulWidget {
  const _BookmarksTab({required this.initial, required this.onSelect, required this.onRemove});
  final Set<int> initial;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onRemove;
  @override
  State<_BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends State<_BookmarksTab> {
  late final Set<int> _marks = {...widget.initial};
  @override
  Widget build(BuildContext context) => BookmarksList(
        bookmarks: _marks,
        onSelect: widget.onSelect,
        onRemove: (p) {
          setState(() => _marks.remove(p));
          widget.onRemove(p);
        },
      );
}
