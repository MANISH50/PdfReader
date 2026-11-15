import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models/reading_state.dart';
import '../../core/security/limits.dart';
import '../../ui/design_system/tokens.dart';

/// Loads the plain text of one page (1-based). Seam for tests.
typedef PageTextLoader = Future<String> Function(int pageNumber);

/// Lazily extracts text from [doc] one page at a time, with the per-page
/// timeout and character cap from [SecurityLimits].
PageTextLoader pdfPageTextLoader(PdfDocument doc) => (pageNumber) async {
      Future<String> load() async {
        var page = doc.pages[pageNumber - 1];
        if (!page.isLoaded) {
          await doc.reloadPages(pageNumbersToReload: [pageNumber]);
          page = doc.pages[pageNumber - 1];
        }
        final text = await page.loadStructuredText();
        final full = text.fullText;
        return full.length > SecurityLimits.maxCharsPerPage
            ? full.substring(0, SecurityLimits.maxCharsPerPage)
            : full;
      }

      return load().timeout(SecurityLimits.pageTextTimeout);
    };

/// Turns extracted page text into readable paragraphs: joins wrapped lines,
/// removes end-of-line hyphenation and splits on blank lines or short lines
/// that end a sentence.
List<String> reflowParagraphs(String text) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').map((l) => l.trim()).toList();
  final nonEmpty = lines.where((l) => l.isNotEmpty).map((l) => l.length).toList()..sort();
  final typical = nonEmpty.isEmpty ? 0 : nonEmpty[(nonEmpty.length * 0.75).floor().clamp(0, nonEmpty.length - 1)];
  final paragraphs = <String>[];
  final buf = StringBuffer();

  void flush() {
    final s = buf.toString().trim();
    if (s.isNotEmpty) paragraphs.add(s);
    buf.clear();
  }

  final sentenceEnd = RegExp(r'[.!?:;"”»)]$');
  final startsLower = RegExp(r'^[a-zà-ÿ]');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) {
      flush();
      continue;
    }
    final current = buf.toString();
    if (current.isEmpty) {
      buf.write(line);
    } else if (current.endsWith('-') && startsLower.hasMatch(line) && !current.endsWith(' -')) {
      final trimmed = current.substring(0, current.length - 1);
      buf
        ..clear()
        ..write(trimmed)
        ..write(line);
    } else {
      buf
        ..write(' ')
        ..write(line);
    }
    final isShort = typical > 0 && line.length < typical * 0.7;
    if (isShort && sentenceEnd.hasMatch(line)) flush();
  }
  flush();
  return paragraphs;
}

/// Text colours for reflow mode that match the page theme.
({Color background, Color text}) reflowColors(PageTheme theme) => switch (theme) {
      PageTheme.light => (background: const Color(0xFFFFFFFF), text: const Color(0xFF1B1B1F)),
      PageTheme.sepia => (background: const Color(0xFFF4ECD8), text: const Color(0xFF5B4636)),
      PageTheme.dark => (background: const Color(0xFF121212), text: const Color(0xFFE3E3E3)),
      PageTheme.night => (background: const Color(0xFF000000), text: const Color(0xFFC8B89A)),
    };

/// Simple reflow / text reading mode: extracted text per page in a scrollable
/// list. Pages are loaded lazily as they scroll into view.
class ReflowView extends StatefulWidget {
  const ReflowView({
    super.key,
    required this.pageCount,
    required this.loadText,
    required this.theme,
    required this.fontScale,
    this.initialPage = 1,
    this.onPageChanged,
    this.onTap,
  });

  final int pageCount;
  final PageTextLoader loadText;
  final PageTheme theme;

  /// Multiplier on the base reading size (18 sp).
  final double fontScale;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onTap;

  @override
  State<ReflowView> createState() => ReflowViewState();
}

class ReflowViewState extends State<ReflowView> {
  static const _maxCachedPages = 64;
  final _cache = <int, Future<List<String>>>{};
  final _scroll = ScrollController();

  /// Contexts of the page items currently built (visible + cache extent).
  final _built = <int, BuildContext>{};
  final _centerKey = UniqueKey();
  late int _anchor = widget.initialPage.clamp(1, widget.pageCount < 1 ? 1 : widget.pageCount);
  int _reported = -1;
  bool _scrollCheckScheduled = false;

  Future<List<String>> _paras(int page) {
    final hit = _cache.remove(page);
    if (hit != null) return _cache[page] = hit; // move to most-recent
    if (_cache.length >= _maxCachedPages) _cache.remove(_cache.keys.first);
    return _cache[page] = () async {
      try {
        return reflowParagraphs(await widget.loadText(page));
      } catch (_) {
        return const <String>[];
      }
    }();
  }

  /// Shows [page] at the top. Pages before it stay reachable by scrolling up.
  void jumpToPage(int page) {
    setState(() {
      _anchor = page.clamp(1, widget.pageCount);
      _reported = -1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealAnchor());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealAnchor());
  }

  /// Puts the anchor page just below the app bar (negative offsets scroll
  /// into the pages built above the centre sliver).
  void _revealAnchor() {
    if (!mounted || !_scroll.hasClients) return;
    final inset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final target = -inset;
    final pos = _scroll.position;
    _scroll.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // The last built page whose top is at or above the reading line is current.
    int? current;
    for (final e in _built.entries) {
      final box = e.value.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= 160 && (current == null || e.key > current)) current = e.key;
    }
    current ??= _built.isEmpty ? _anchor : _built.keys.reduce((a, b) => a < b ? a : b);
    if (current != _reported) {
      _reported = current;
      widget.onPageChanged?.call(current);
    }
  }

  Widget _pageItem(int page, TextStyle style, TextStyle headerStyle) => _TrackedPage(
        key: ValueKey('viewer.page.$page'),
        page: page,
        registry: _built,
        child: Padding(
          padding: EdgeInsets.zero,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.md),
                    child: Semantics(header: true, child: Text('Page $page', style: headerStyle)),
                  ),
                  FutureBuilder<List<String>>(
                    future: _paras(page),
                    builder: (context, snap) {
                      if (!snap.hasData) {
                        return const Padding(
                          padding: EdgeInsets.all(Space.lg),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final paras = snap.data!;
                      if (paras.isEmpty) {
                        return Text('No text on this page (it may be an image or scan).',
                            style: style.copyWith(fontStyle: FontStyle.italic, fontSize: 15));
                      }
                      return SelectionArea(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final p in paras)
                              Padding(
                                padding: const EdgeInsets.only(bottom: Space.md),
                                child: Text(p, style: style),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final colors = reflowColors(widget.theme);
    final style = TextStyle(color: colors.text, fontSize: 18 * widget.fontScale, height: 1.55);
    final headerStyle = TextStyle(color: colors.text.withValues(alpha: 0.6), fontSize: 13);
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final before = _anchor - 1; // pages 1.._anchor-1, built upward lazily
    final after = widget.pageCount - _anchor + 1; // pages _anchor..N
    const hPad = EdgeInsets.symmetric(horizontal: Space.lg);
    return ColoredBox(
      color: colors.background,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            // Notifications can arrive during layout; measure after the frame.
            if (!_scrollCheckScheduled) {
              _scrollCheckScheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _scrollCheckScheduled = false;
                if (mounted) _onScroll();
              });
            }
            return false;
          },
          child: Scrollbar(
            controller: _scroll,
            child: CustomScrollView(
              key: const Key('viewer.scroll'),
              controller: _scroll,
              center: _centerKey,
              slivers: [
                // Space for the app bar above page 1 (reverse-growing slivers
                // before the centre are laid out bottom-up, so this sits on top).
                SliverToBoxAdapter(child: SizedBox(height: topInset)),
                SliverPadding(
                  padding: hPad,
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _pageItem(_anchor - 1 - i, style, headerStyle),
                      childCount: before < 0 ? 0 : before,
                    ),
                  ),
                ),
                SliverPadding(
                  key: _centerKey,
                  padding: hPad.copyWith(bottom: Space.xxl * 2),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _pageItem(_anchor + i, style, headerStyle),
                      childCount: after < 0 ? 0 : after,
                    ),
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

/// Registers its context while mounted so scroll tracking only looks at
/// pages that are actually built.
class _TrackedPage extends StatefulWidget {
  const _TrackedPage({super.key, required this.page, required this.registry, required this.child});
  final int page;
  final Map<int, BuildContext> registry;
  final Widget child;
  @override
  State<_TrackedPage> createState() => _TrackedPageState();
}

class _TrackedPageState extends State<_TrackedPage> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.page] = context;
  }

  @override
  void dispose() {
    if (identical(widget.registry[widget.page], context)) widget.registry.remove(widget.page);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
