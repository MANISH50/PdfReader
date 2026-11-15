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
  final _cache = <int, Future<List<String>>>{};
  late final ScrollController _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  late int _start = widget.initialPage.clamp(1, widget.pageCount < 1 ? 1 : widget.pageCount);
  int _reported = -1;

  Future<List<String>> _paras(int page) => _cache.putIfAbsent(page, () async {
        try {
          return reflowParagraphs(await widget.loadText(page));
        } catch (_) {
          return const <String>[];
        }
      });

  /// Shows [page] at the top (pages before it are re-added lazily on scroll up).
  void jumpToPage(int page) {
    setState(() {
      _start = page.clamp(1, widget.pageCount);
      _reported = -1;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // The first page whose header is at or above the viewport top is current.
    var current = _start;
    for (final e in _keys.entries) {
      final ctx = e.value.currentContext;
      final box = ctx?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= 160 && e.key > current) current = e.key;
    }
    if (current != _reported) {
      _reported = current;
      widget.onPageChanged?.call(current);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = reflowColors(widget.theme);
    final style = TextStyle(color: colors.text, fontSize: 18 * widget.fontScale, height: 1.55);
    final headerStyle = TextStyle(color: colors.text.withValues(alpha: 0.6), fontSize: 13);
    final count = widget.pageCount - _start + 1;
    return ColoredBox(
      color: colors.background,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _onScroll();
            return false;
          },
          child: Scrollbar(
            controller: _scroll,
            child: ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                Space.lg, MediaQuery.paddingOf(context).top + kToolbarHeight, Space.lg, Space.xxl * 2),
              itemCount: count < 0 ? 0 : count,
              itemBuilder: (context, i) {
                final page = _start + i;
                final key = _keys.putIfAbsent(page, GlobalKey.new);
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      key: key,
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
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
