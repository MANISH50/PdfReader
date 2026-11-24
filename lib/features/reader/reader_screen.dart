import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/documents/document_kind.dart';
import '../../core/models/document_ref.dart';
import '../../core/models/reading_state.dart';
import '../../core/providers.dart';
import '../../core/security/link_policy.dart';
import '../../ui/design_system/adaptive.dart';
import '../../ui/design_system/tokens.dart';
import '../../ui/design_system/widgets/fancy.dart' show GlassBar;
import '../viewer/viewer_dialogs.dart' show confirmExternalLink;
import 'block_view.dart';
import 'reader_loader.dart';
import 'reader_model.dart';
import 'sheet_view.dart';
import 'text_markdown_parser.dart' show headingSlug, kMaxLineChars;

Future<bool> _launchExternal(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Read-only reader for DOCX, Markdown, plain-text and spreadsheet files.
///
/// The document is parsed off the UI isolate ([loadReaderDocument]) into a
/// flat list of blocks rendered lazily, so multi-megabyte logs stay smooth.
/// The reading position is stored in [ReadingState]: `pageNumber` holds the
/// first visible block (1-based) and `zoom` the scroll fraction.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.document, this.loader, this.urlOpener});

  final DocumentRef document;
  final ReaderLoader? loader;
  final Future<bool> Function(Uri uri)? urlOpener;

  @override
  ConsumerState<ReaderScreen> createState() => ReaderScreenState();
}

class ReaderScreenState extends ConsumerState<ReaderScreen> {
  static const maxHits = 5000;
  static const _maxContentWidth = 760.0;

  ReaderDocument? _doc;
  String? _error;
  ReadingState _state = const ReadingState();

  PageTheme? _theme;
  double _fontScale = 1.0;
  bool _wrap = true;
  bool _chrome = true;

  bool _searching = false;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  Timer? _debounce;
  List<String>? _lowerTexts;
  List<ReaderHit> _hits = const [];
  Map<int, List<ReaderHit>> _hitsByBlock = const {};
  int _current = -1;

  // Spreadsheets: selected sheet and cell search hits across all sheets.
  int _sheet = 0;
  int _sheetStartRow = 0;
  final _sheetKey = GlobalKey<SheetViewState>();
  List<({int sheet, int row, int col})> _cellHits = const [];

  int get _hitCount => _doc?.sheets != null ? _cellHits.length : _hits.length;

  /// Reading position of a sheet, packed into [ReadingState.pageNumber]
  /// (sheet × 1 000 000 + row + 1; rows are capped at 100 000).
  static int _packSheetPos(int sheet, int row) => sheet * 1000000 + row + 1;

  final _scroll = ScrollController();
  final _listKey = GlobalKey();
  final _built = <int, BuildContext>{};
  Timer? _saveTimer;
  bool _linkTapped = false;
  Offset? _downAt;
  DateTime? _downTime;

  /// Hits of the current search (for tests and accessibility).
  List<ReaderHit> get hits => _hits;
  int get currentHit => _current;

  late final _store = ref.read(readingStateStoreProvider);
  double _topInset = kToolbarHeight;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final doc = await (widget.loader ?? loadReaderDocument)(widget.document);
      ReadingState state = const ReadingState();
      try {
        state = await _store.load(widget.document.id);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _state = state;
      });
      final sheets = doc.sheets;
      if (sheets != null) {
        final packed = state.pageNumber - 1;
        final sh = packed ~/ 1000000;
        if (sh < sheets.length) {
          setState(() {
            _sheet = sh;
            _sheetStartRow = packed % 1000000;
          });
        }
      } else if (state.pageNumber > 1) {
        SchedulerBinding.instance.addPostFrameCallback((_) => _scrollToBlock(state.pageNumber - 1, alignment: 0));
      }
      _scheduleSave();
    } on ReaderOpenException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = const ReaderOpenException(ReaderFailure.damaged).message);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_doc != null) _persist();
    _debounce?.cancel();
    _query.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- reading position ------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      _capturePosition();
      _persist();
    });
  }

  /// Records the first visible block and the scroll fraction in [_state].
  void _capturePosition() {
    if (_doc?.sheets != null) {
      final row = _sheetKey.currentState?.topRow ?? _sheetStartRow;
      _state = _state.copyWith(pageNumber: _packSheetPos(_sheet, row));
      return;
    }
    final top = _topVisibleBlock();
    double? fraction;
    if (_scroll.hasClients && _scroll.position.maxScrollExtent > 0) {
      fraction = (_scroll.position.pixels / _scroll.position.maxScrollExtent).clamp(0.0, 1.0);
    }
    _state = _state.copyWith(pageNumber: (top ?? _state.pageNumber - 1) + 1, zoom: fraction);
  }

  void _persist() {
    _state = _state.copyWith(lastOpened: DateTime.now());
    unawaited(_store.save(widget.document.id, _state).catchError((Object _) {}));
  }

  int? _topVisibleBlock() {
    final list = _listKey.currentContext?.findRenderObject();
    if (list is! RenderBox || !list.attached) return null;
    final top = _topInset;
    int? best;
    for (final e in _built.entries) {
      if (!e.value.mounted) continue;
      final box = e.value.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero, ancestor: list).dy;
      if (dy + box.size.height > top && (best == null || e.key < best)) best = e.key;
    }
    return best;
  }

  /// Brings block [index] into view. Items are built lazily with unknown
  /// heights, so jump by estimate until the item is built, then align it.
  Future<void> _scrollToBlock(int index, {double alignment = 0.3}) async {
    final topInset = _topInset;
    for (var attempt = 0; attempt < 16 && mounted && _scroll.hasClients; attempt++) {
      final ctx = _built[index];
      if (ctx != null && ctx.mounted) {
        final box = ctx.findRenderObject();
        if (box is RenderObject && box.attached) {
          final viewport = RenderAbstractViewport.maybeOf(box);
          if (viewport != null) {
            final pos = _scroll.position;
            final target = viewport.getOffsetToReveal(box, 0).offset -
                (pos.viewportDimension - topInset) * alignment -
                (alignment == 0 ? topInset - Space.sm : 0);
            _scroll.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
          }
          return;
        }
      }
      final keys = _built.keys.where((k) => _built[k]!.mounted).toList()..sort();
      final pos = _scroll.position;
      var avg = 40.0;
      var measured = 0.0, count = 0;
      for (final k in keys) {
        final b = _built[k]!.findRenderObject();
        if (b is RenderBox && b.hasSize) {
          measured += b.size.height;
          count++;
        }
      }
      if (count > 0) avg = math.max(8, measured / count);
      final first = keys.isEmpty ? 0 : keys.first;
      final target = pos.pixels + (index - first) * avg;
      _scroll.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  // ---- search ----------------------------------------------------------------

  void _openSearch() {
    setState(() {
      _searching = true;
      _chrome = true;
    });
    _queryFocus.requestFocus();
  }

  void _closeSearch() {
    _debounce?.cancel();
    _query.clear();
    setState(() {
      _searching = false;
      _hits = const [];
      _hitsByBlock = const {};
      _cellHits = const [];
      _current = -1;
    });
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => runSearch(q));
  }

  /// Finds [query] (case-insensitive) and jumps to the first hit.
  void runSearch(String query) {
    final doc = _doc;
    if (doc == null) return;
    final needle = query.toLowerCase();
    if (doc.sheets case final sheets?) {
      _searchSheets(sheets, needle);
      return;
    }
    final hits = <ReaderHit>[];
    if (needle.isNotEmpty) {
      final texts = _lowerTexts ??= [for (final b in doc.blocks) b.searchText.toLowerCase()];
      outer:
      for (var i = 0; i < texts.length; i++) {
        final t = texts[i];
        var from = 0;
        while (true) {
          final j = t.indexOf(needle, from);
          if (j < 0) break;
          hits.add(ReaderHit(i, j, needle.length));
          if (hits.length >= maxHits) break outer;
          from = j + needle.length;
        }
      }
    }
    final byBlock = <int, List<ReaderHit>>{};
    for (final h in hits) {
      (byBlock[h.block] ??= []).add(h);
    }
    setState(() {
      _hits = hits;
      _hitsByBlock = byBlock;
      _current = hits.isEmpty ? -1 : 0;
    });
    if (hits.isNotEmpty) unawaited(_scrollToBlock(hits.first.block));
  }

  void _searchSheets(List<SheetData> sheets, String needle) {
    final hits = <({int sheet, int row, int col})>[];
    if (needle.isNotEmpty) {
      outer:
      for (var sh = 0; sh < sheets.length; sh++) {
        final rows = sheets[sh].rows;
        for (var r = 0; r < rows.length; r++) {
          final row = rows[r];
          for (var c = 0; c < row.length; c++) {
            if (row[c].toLowerCase().contains(needle)) {
              hits.add((sheet: sh, row: r, col: c));
              if (hits.length >= maxHits) break outer;
            }
          }
        }
      }
    }
    // Start at the first hit in the sheet being viewed.
    final first = hits.indexWhere((h) => h.sheet >= _sheet);
    setState(() {
      _cellHits = hits;
      _current = hits.isEmpty ? -1 : (first < 0 ? 0 : first);
    });
    if (hits.isNotEmpty) _showCellHit();
  }

  void _showCellHit() {
    final h = _cellHits[_current];
    if (h.sheet != _sheet) {
      setState(() {
        _sheet = h.sheet;
        _sheetStartRow = h.row;
      });
    }
    SchedulerBinding.instance.addPostFrameCallback((_) => _sheetKey.currentState?.scrollToCell((row: h.row, col: h.col)));
  }

  void _step(int delta) {
    if (_doc?.sheets != null) {
      if (_cellHits.isEmpty) return;
      setState(() => _current = (_current + delta) % _cellHits.length);
      _showCellHit();
      return;
    }
    if (_hits.isEmpty) return;
    setState(() => _current = (_current + delta) % _hits.length);
    unawaited(_scrollToBlock(_hits[_current].block));
  }

  String get _countLabel {
    final n = _hitCount;
    if (n == 0) return _query.text.isEmpty ? '' : 'No matches';
    final more = n >= maxHits ? '+' : '';
    return '${_current + 1} of $n$more';
  }

  // ---- actions ---------------------------------------------------------------

  void _snack(String text) => showAppSnackBar(context, text);

  Future<void> _onLink(String href) async {
    _linkTapped = true;
    final h = href.trim();
    if (h.startsWith('#')) {
      final slug = Uri.decodeComponent(h.substring(1)).toLowerCase();
      final blocks = _doc?.blocks ?? const <RBlock>[];
      for (var i = 0; i < blocks.length; i++) {
        final b = blocks[i];
        if (b is TextBlock && b.headingLevel > 0 && headingSlug(b.searchText) == slug) {
          unawaited(_scrollToBlock(i, alignment: 0));
          return;
        }
      }
      return;
    }
    final uri = Uri.tryParse(h);
    if (uri == null || !uri.hasScheme) {
      // Relative links point at other files we don't have: ignore.
      _snack('This link points to another file and can’t be opened.');
      return;
    }
    switch (LinkPolicy.decide(uri: uri)) {
      case LinkDecision.internal:
        return;
      case LinkDecision.confirmExternal:
        if (!mounted) return;
        if (await confirmExternalLink(context, uri)) {
          final ok = await (widget.urlOpener ?? _launchExternal)(uri);
          if (!ok && mounted) _snack('No app available to open this link.');
        }
      case LinkDecision.blocked:
        _snack('Blocked a link that could be unsafe.');
    }
  }

  Future<void> _share() async {
    try {
      await ref.read(shareServiceProvider).shareFiles([widget.document.path], subject: widget.document.displayName);
    } catch (_) {
      if (mounted) _snack('Couldn’t share this file.');
    }
  }

  void _showTextOptions(PageTheme theme) {
    final isText = _doc?.kind == DocumentKind.text;
    showAppBottomSheet<void>(
      context,
      title: 'Text',
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) {
          void update(VoidCallback f) {
            setState(f);
            setSheet(() {});
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.text_decrease, size: 18),
                Expanded(
                  child: Slider(
                    key: const Key('reader.fontSize'),
                    value: _fontScale,
                    min: 0.8,
                    max: 2.0,
                    divisions: 12,
                    label: '${(_fontScale * 100).round()}%',
                    semanticFormatterCallback: (v) => 'Text size ${(v * 100).round()} percent',
                    onChanged: (v) => update(() => _fontScale = v),
                  ),
                ),
                const Icon(Icons.text_increase, size: 22),
              ]),
              const SizedBox(height: Space.sm),
              AdaptiveSegmented<PageTheme>(
                semanticLabel: 'Page colour',
                segments: const [
                  Segment(PageTheme.light, 'Light', key: Key('reader.theme.light')),
                  Segment(PageTheme.sepia, 'Sepia', key: Key('reader.theme.sepia')),
                  Segment(PageTheme.dark, 'Dark', key: Key('reader.theme.dark')),
                  Segment(PageTheme.night, 'Night', key: Key('reader.theme.night')),
                ],
                selected: _theme ?? theme,
                onChanged: (t) => update(() => _theme = t),
              ),
              if (isText) ...[
                const SizedBox(height: Space.sm),
                SwitchListTile.adaptive(
                  key: const Key('reader.wrap'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Wrap long lines'),
                  value: _wrap,
                  onChanged: (v) => update(() => _wrap = v),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  // ---- tap to hide chrome ------------------------------------------------------

  void _pointerDown(PointerDownEvent e) {
    _downAt = e.position;
    _downTime = DateTime.now();
    _linkTapped = false;
  }

  void _pointerUp(PointerUpEvent e) {
    final at = _downAt, t = _downTime;
    if (at == null || t == null) return;
    if ((e.position - at).distance > 12 || DateTime.now().difference(t) > const Duration(milliseconds: 300)) return;
    // Link recognizers fire after pointer-up dispatch; decide afterwards.
    scheduleMicrotask(() {
      if (!mounted || _linkTapped || _searching) return;
      setState(() => _chrome = !_chrome);
    });
  }

  // ---- build -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value;
    final theme = _theme ?? settings?.defaultPageTheme ?? PageTheme.light;
    final doc = _doc;
    final style = ReaderStyle.of(theme, fontScale: _fontScale, monospace: doc?.monospace ?? false);
    final mq = MediaQuery.of(context);
    final barHeight = mq.padding.top + kToolbarHeight + Space.sm + 4;
    _topInset = barHeight;
    final dark = theme == PageTheme.dark || theme == PageTheme.night;

    final Widget content;
    if (_error != null) {
      content = _ErrorView(message: _error!, style: style);
    } else if (doc == null) {
      content = Center(child: AdaptiveProgress(color: style.muted));
    } else if (doc.sheets != null) {
      content = _sheets(doc, style, barHeight, mq);
    } else {
      content = _list(doc, style, barHeight, mq);
    }

    return Theme(
      data: Theme.of(context).copyWith(
        textSelectionTheme: TextSelectionThemeData(selectionColor: style.link.withValues(alpha: 0.3)),
      ),
      child: Scaffold(
        key: const Key('reader.screen'),
        backgroundColor: style.background,
        body: Stack(children: [
          Positioned.fill(child: content),
          AnimatedPositioned(
            duration: Motion.normal,
            curve: Motion.standard,
            left: 0,
            right: 0,
            top: _chrome ? 0 : -barHeight - 4,
            child: SafeArea(
              bottom: false,
              minimum: const EdgeInsets.fromLTRB(Space.sm + 2, Space.xs + 2, Space.sm + 2, 0),
              child: GlassBar(
                color: style.background,
                borderColor: style.foreground,
                child: MediaQuery.removePadding(context: context, removeTop: true, child: _appBar(style, theme, dark)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _list(ReaderDocument doc, ReaderStyle style, double barHeight, MediaQueryData mq) {
    final notice = doc.notice;
    final wrap = _wrap || doc.kind != DocumentKind.text;
    return SelectionArea(
      child: Listener(
        onPointerDown: _pointerDown,
        onPointerUp: _pointerUp,
        child: NotificationListener<ScrollEndNotification>(
          onNotification: (_) {
            _capturePosition();
            _scheduleSave();
            return false;
          },
          child: LayoutBuilder(builder: (context, c) {
            final side = math.max(Space.md + 4, (c.maxWidth - _maxContentWidth) / 2);
            Widget list = Scrollbar(
              controller: _scroll,
              interactive: true,
              child: ListView.builder(
                key: _listKey,
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(wrap ? side : Space.md, barHeight + Space.sm, wrap ? side : Space.md,
                    mq.padding.bottom + Space.xxl),
                itemCount: doc.blocks.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return notice == null ? const SizedBox.shrink() : _Notice(text: notice, style: style);
                  }
                  final index = i - 1;
                  final hits = _hitsByBlock[index] ?? const <ReaderHit>[];
                  final current = _current >= 0 && _current < _hits.length && _hits[_current].block == index
                      ? _hits[_current]
                      : null;
                  return _Tracked(
                    key: ValueKey(index),
                    index: index,
                    registry: _built,
                    child: ReaderBlockView(
                      block: doc.blocks[index],
                      style: style,
                      hits: hits,
                      currentHit: current,
                      onLink: _onLink,
                    ),
                  );
                },
              ),
            );
            if (!wrap) {
              // No wrapping: one wide page that scrolls sideways.
              var longest = 0;
              for (final b in doc.blocks) {
                if (b is LineBlock && b.text.length > longest) longest = b.text.length;
              }
              final width = math.max(c.maxWidth, math.min(longest, kMaxLineChars) * style.fontSize * 0.62 + Space.xl);
              list = SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: width, height: c.maxHeight, child: list),
              );
            }
            return DefaultTextStyle.merge(style: style.body, child: list);
          }),
        ),
      ),
    );
  }

  Widget _sheets(ReaderDocument doc, ReaderStyle style, double barHeight, MediaQueryData mq) {
    final sheets = doc.sheets!;
    final sheet = sheets[_sheet.clamp(0, sheets.length - 1)];
    final hit = _current >= 0 && _current < _cellHits.length ? _cellHits[_current] : null;
    final hitSet = <CellRef>{
      for (final h in _cellHits)
        if (h.sheet == _sheet) (row: h.row, col: h.col),
    };
    final tabs = sheets.length > 1;
    return Column(children: [
      if (doc.notice != null) SizedBox(height: barHeight),
      if (doc.notice != null) _Notice(text: doc.notice!, style: style),
      Expanded(
        child: SheetView(
          key: _sheetKey,
          sheet: sheet,
          style: style,
          topInset: doc.notice != null ? 0 : barHeight,
          bottomInset: tabs ? 0 : mq.padding.bottom,
          hits: hitSet,
          current: hit != null && hit.sheet == _sheet ? (row: hit.row, col: hit.col) : null,
          initialRow: _sheetStartRow,
          onCellTap: _showCell,
          onScrollEnd: _scheduleSave,
        ),
      ),
      if (tabs)
        Container(
          decoration: BoxDecoration(
            color: style.background,
            border: Border(top: BorderSide(color: style.border.withValues(alpha: 0.5), width: 0.5)),
          ),
          padding: EdgeInsets.only(bottom: mq.padding.bottom),
          child: SheetTabs(
            key: const Key('reader.sheetTabs'),
            names: [for (final s in sheets) s.name],
            selected: _sheet,
            style: style,
            onSelected: (i) {
              if (i == _sheet) return;
              setState(() {
                _sheet = i;
                _sheetStartRow = 0;
              });
              _scheduleSave();
            },
          ),
        ),
    ]);
  }

  void _showCell(CellRef cell, String text) {
    showAppBottomSheet<void>(
      context,
      title: '${columnLabel(cell.col)}${cell.row + 1}',
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(text, key: const Key('reader.cell.text'), style: Theme.of(c).textTheme.bodyLarge),
          const SizedBox(height: Space.md),
          FilledButton.tonalIcon(
            key: const Key('reader.cell.copy'),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy'),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: text)));
              Navigator.of(c).pop();
              _snack('Copied');
            },
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar(ReaderStyle style, PageTheme theme, bool dark) {
    final fg = style.foreground;
    return AppBar(
      key: const Key('reader.appBar'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: fg),
      actionsIconTheme: IconThemeData(color: fg),
      titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
      title: _searching
          ? TextField(
              key: const Key('reader.search.field'),
              controller: _query,
              focusNode: _queryFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: fg, fontSize: 16),
              cursorColor: style.link,
              decoration: InputDecoration(
                hintText: 'Find in document',
                hintStyle: TextStyle(color: style.muted),
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: _onQueryChanged,
              onSubmitted: (q) {
                _debounce?.cancel();
                if (_hitCount > 0 && q.toLowerCase() == _lastQuery) {
                  _step(1);
                } else {
                  runSearch(q);
                }
                _lastQuery = q.toLowerCase();
                _queryFocus.requestFocus();
              },
            )
          : Text(widget.document.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: _searching
          ? [
              Center(
                child: Text(
                  _countLabel,
                  key: const Key('reader.search.count'),
                  style: TextStyle(color: style.muted, fontSize: 13),
                ),
              ),
              IconButton(
                key: const Key('reader.search.prev'),
                tooltip: 'Previous match',
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
                onPressed: _hitCount == 0 ? null : () => _step(-1),
              ),
              IconButton(
                key: const Key('reader.search.next'),
                tooltip: 'Next match',
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                onPressed: _hitCount == 0 ? null : () => _step(1),
              ),
              IconButton(
                key: const Key('reader.search.close'),
                tooltip: 'Close search',
                icon: const Icon(Icons.close_rounded),
                onPressed: _closeSearch,
              ),
            ]
          : [
              IconButton(
                key: const Key('reader.search'),
                tooltip: 'Search',
                icon: const Icon(Icons.search_rounded),
                onPressed: _doc == null ? null : _openSearch,
              ),
              IconButton(
                key: const Key('reader.textOptions'),
                tooltip: 'Text size and page colour',
                icon: const Icon(Icons.text_fields_rounded),
                onPressed: () => _showTextOptions(theme),
              ),
              IconButton(
                key: const Key('reader.share'),
                tooltip: 'Share',
                icon: Icon(Icons.adaptive.share),
                onPressed: _share,
              ),
              const SizedBox(width: Space.xs),
            ],
    );
  }

  String? _lastQuery;
}

/// Registers its context under [index] while mounted (for scroll-to-block).
class _Tracked extends StatefulWidget {
  const _Tracked({super.key, required this.index, required this.registry, required this.child});
  final int index;
  final Map<int, BuildContext> registry;
  final Widget child;

  @override
  State<_Tracked> createState() => _TrackedState();
}

class _TrackedState extends State<_Tracked> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.index] = context;
  }

  @override
  void didUpdateWidget(_Tracked old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      if (identical(old.registry[old.index], context)) old.registry.remove(old.index);
      widget.registry[widget.index] = context;
    }
  }

  @override
  void dispose() {
    if (identical(widget.registry[widget.index], context)) widget.registry.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.style});
  final String text;
  final ReaderStyle style;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Space.md),
        child: Container(
          key: const Key('reader.notice'),
          padding: const EdgeInsets.symmetric(horizontal: Space.md - 4, vertical: Space.sm),
          decoration: BoxDecoration(
            color: style.codeBackground,
            borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
          ),
          child: Row(children: [
            Icon(Icons.info_outline_rounded, size: 18, color: style.muted),
            const SizedBox(width: Space.sm),
            Expanded(child: Text(text, style: TextStyle(color: style.muted, fontSize: 13, height: 1.35))),
          ]),
        ),
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.style});
  final String message;
  final ReaderStyle style;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.description_outlined, size: 56, color: style.muted),
            const SizedBox(height: Space.md),
            Text(
              message,
              key: const Key('reader.error'),
              textAlign: TextAlign.center,
              style: TextStyle(color: style.foreground, fontSize: 16, height: 1.4),
            ),
            const SizedBox(height: Space.lg),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Back'),
            ),
          ]),
        ),
      );
}
