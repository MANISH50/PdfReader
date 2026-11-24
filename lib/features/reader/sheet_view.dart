import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/design_system/tokens.dart';
import 'block_view.dart' show ReaderStyle;
import 'reader_model.dart';

/// A cell position in a sheet.
typedef CellRef = ({int row, int col});

final _numeric = RegExp(r'^[-+]?[\d.,]+%?$|^[-+]?\d+(\.\d+)?[eE][-+]?\d+$');

/// Lazily built spreadsheet grid. The column-letter header and the first
/// row stay visible while scrolling down; row numbers stay visible while
/// scrolling sideways. Only visible rows are built, so 100 000-row CSVs
/// scroll smoothly.
class SheetView extends StatefulWidget {
  const SheetView({
    super.key,
    required this.sheet,
    required this.style,
    this.topInset = 0,
    this.bottomInset = 0,
    this.hits = const {},
    this.current,
    this.initialRow = 0,
    this.onCellTap,
    this.onScrollEnd,
  });

  final SheetData sheet;
  final ReaderStyle style;
  final double topInset, bottomInset;
  final Set<CellRef> hits;
  final CellRef? current;
  final int initialRow;
  final void Function(CellRef cell, String text)? onCellTap;
  final VoidCallback? onScrollEnd;

  @override
  State<SheetView> createState() => SheetViewState();
}

class SheetViewState extends State<SheetView> {
  final _v = ScrollController();
  final _gutter = ScrollController();
  final _h = ScrollController();
  List<double> _widths = const [];
  double _fontSize = 0;

  double get _cellFont => widget.style.fontSize * 0.82;
  double get rowHeight => _cellFont * 1.3 + 18;
  double get _gutterWidth {
    final digits = math.max(2, '${widget.sheet.rows.length}'.length);
    return digits * _cellFont * 0.62 + 22;
  }

  /// First data row visible below the sticky header (0-based sheet row).
  int get topRow => _v.hasClients ? (_v.offset / rowHeight).floor() + 1 : widget.initialRow;

  @override
  void initState() {
    super.initState();
    _measure();
    _v.addListener(() {
      if (_gutter.hasClients && _gutter.offset != _v.offset) _gutter.jumpTo(_v.offset);
    });
    if (widget.initialRow > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => scrollToCell((row: widget.initialRow, col: 0), align: 0));
    }
  }

  @override
  void didUpdateWidget(SheetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newSheet = !identical(oldWidget.sheet, widget.sheet);
    if (newSheet || _fontSize != widget.style.fontSize) _measure();
    if (newSheet) {
      // Another sheet: start at its top-left (or the requested row).
      if (_v.hasClients) _v.jumpTo(0);
      if (_h.hasClients) _h.jumpTo(0);
      if (widget.initialRow > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) => scrollToCell((row: widget.initialRow, col: 0), align: 0));
      }
    }
  }

  @override
  void dispose() {
    _v.dispose();
    _gutter.dispose();
    _h.dispose();
    super.dispose();
  }

  void _measure() {
    _fontSize = widget.style.fontSize;
    final s = widget.sheet;
    final chars = List<int>.filled(s.columnCount, 1);
    final sample = math.min(s.rows.length, 200);
    for (var r = 0; r < sample; r++) {
      final row = s.rows[r];
      for (var c = 0; c < row.length; c++) {
        final v = row[c];
        final n = v.contains('\n') ? v.split('\n').first.length : v.length;
        if (n > chars[c]) chars[c] = math.min(n, 40);
      }
    }
    _widths = [for (final n in chars) (n * _cellFont * 0.6 + 22).clamp(64.0, 320.0)];
  }

  /// Scrolls so [cell] is visible ([align] 0 = top, 0.35 = upper third).
  void scrollToCell(CellRef cell, {double align = 0.35}) {
    if (!mounted) return;
    if (_v.hasClients && cell.row > 0) {
      final p = _v.position;
      final y = (cell.row - 1) * rowHeight - (p.viewportDimension - rowHeight) * align;
      _v.jumpTo(y.clamp(p.minScrollExtent, p.maxScrollExtent));
    }
    if (_h.hasClients && cell.col < _widths.length) {
      var x = 0.0;
      for (var c = 0; c < cell.col; c++) {
        x += _widths[c];
      }
      final p = _h.position;
      final w = _widths[cell.col];
      if (x < p.pixels || x + w > p.pixels + p.viewportDimension) {
        _h.jumpTo((x - p.viewportDimension * 0.3).clamp(p.minScrollExtent, p.maxScrollExtent));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final sheet = widget.sheet;
    if (sheet.rows.isEmpty || sheet.columnCount == 0) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topInset),
        child: Center(
          child: Text(
            'This sheet is empty',
            style: TextStyle(color: s.muted, fontSize: s.fontSize * 0.9),
          ),
        ),
      );
    }
    final total = _widths.fold<double>(0, (a, b) => a + b);
    final rh = rowHeight;
    final headerBg = Color.alphaBlend(s.link.withValues(alpha: 0.10), s.background);
    final gutterBg = Color.alphaBlend(s.foreground.withValues(alpha: 0.04), s.background);
    final line = s.border.withValues(alpha: 0.35);
    final dataRows = sheet.rows.length - 1;

    Widget letters() => Row(
      children: [
        for (var c = 0; c < _widths.length; c++)
          _box(
            width: _widths[c],
            height: rh * 0.8,
            color: gutterBg,
            line: line,
            center: true,
            child: Text(
              columnLabel(c),
              style: TextStyle(color: s.muted, fontSize: _cellFont * 0.85, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );

    Widget dataRow(int r, {bool header = false}) {
      final row = sheet.rows[r];
      return Row(
        children: [
          for (var c = 0; c < _widths.length; c++)
            _cell(r, c, c < row.length ? row[c] : '', header: header, line: line, bg: header ? headerBg : null),
        ],
      );
    }

    final grid = Scrollbar(
      controller: _h,
      child: SingleChildScrollView(
        controller: _h,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: total,
          child: Column(
            children: [
              letters(),
              dataRow(0, header: dataRows > 0),
              Expanded(
                child: Scrollbar(
                  controller: _v,
                  interactive: true,
                  child: NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      widget.onScrollEnd?.call();
                      return false;
                    },
                    child: ListView.builder(
                      controller: _v,
                      itemExtent: rh,
                      padding: EdgeInsets.only(bottom: widget.bottomInset + Space.xl),
                      itemCount: dataRows,
                      itemBuilder: (_, i) => dataRow(i + 1),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final gutterStyle = TextStyle(
      color: s.muted,
      fontSize: _cellFont * 0.85,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final gutter = SizedBox(
      width: _gutterWidth,
      child: Column(
        children: [
          _box(width: _gutterWidth, height: rh * 0.8, color: gutterBg, line: line, child: const SizedBox.shrink()),
          _box(
            width: _gutterWidth,
            height: rh,
            color: gutterBg,
            line: line,
            center: true,
            child: Text('1', style: gutterStyle),
          ),
          Expanded(
            child: ListView.builder(
              controller: _gutter,
              physics: const NeverScrollableScrollPhysics(),
              itemExtent: rh,
              padding: EdgeInsets.only(bottom: widget.bottomInset + Space.xl),
              itemCount: dataRows,
              itemBuilder: (_, i) => _box(
                width: _gutterWidth,
                height: rh,
                color: gutterBg,
                line: line,
                center: true,
                child: Text('${i + 2}', style: gutterStyle),
              ),
            ),
          ),
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.only(top: widget.topInset),
      child: Column(
        children: [
          if (sheet.truncated)
            Container(
              key: const Key('reader.sheet.truncated'),
              width: double.infinity,
              color: s.codeBackground,
              padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs + 2),
              child: Text(
                'Large sheet: showing the first ${sheet.rows.length} rows.',
                style: TextStyle(color: s.muted, fontSize: 12.5),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                gutter,
                Expanded(child: grid),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _box({
    required double width,
    required double height,
    required Color line,
    Color? color,
    bool center = false,
    required Widget child,
  }) => Container(
    width: width,
    height: height,
    alignment: center ? Alignment.center : AlignmentDirectional.centerStart,
    padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2),
    decoration: BoxDecoration(
      color: color,
      border: Border(
        right: BorderSide(color: line, width: 0.6),
        bottom: BorderSide(color: line, width: 0.6),
      ),
    ),
    child: child,
  );

  Widget _cell(int r, int c, String text, {required bool header, required Color line, Color? bg}) {
    final s = widget.style;
    final ref = (row: r, col: c);
    final isCurrent = widget.current == ref;
    final isHit = isCurrent || (widget.hits.isNotEmpty && widget.hits.contains(ref));
    final shown = text.contains('\n') ? text.replaceAll(RegExp(r'\s*\n\s*'), ' ⏎ ') : text;
    final numeric = !header && _numeric.hasMatch(text.trim());
    return Semantics(
      label: '${columnLabel(c)}${r + 1}${text.isEmpty ? ', empty' : ''}',
      button: text.isNotEmpty,
      child: InkWell(
        onTap: text.isEmpty || widget.onCellTap == null ? null : () => widget.onCellTap!(ref, text),
        child: Container(
          width: _widths[c],
          height: rowHeight,
          alignment: numeric ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2),
          decoration: BoxDecoration(
            color: isCurrent ? s.currentHit : (isHit ? s.hit : bg),
            border: Border(
              right: BorderSide(color: line, width: 0.6),
              bottom: BorderSide(color: line, width: 0.6),
            ),
          ),
          child: Text(
            shown,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(
              color: s.foreground,
              fontSize: _cellFont,
              fontWeight: header ? FontWeight.w700 : FontWeight.w400,
              fontFeatures: numeric ? const [FontFeature.tabularFigures()] : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Sheet switcher shown under the grid when a workbook has several sheets.
class SheetTabs extends StatelessWidget {
  const SheetTabs({
    super.key,
    required this.names,
    required this.selected,
    required this.onSelected,
    required this.style,
  });
  final List<String> names;
  final int selected;
  final ValueChanged<int> onSelected;
  final ReaderStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        itemCount: names.length,
        separatorBuilder: (_, _) => const SizedBox(width: Space.xs + 2),
        itemBuilder: (_, i) {
          final on = i == selected;
          return Center(
            child: Material(
              color: on ? s.link : s.foreground.withValues(alpha: 0.07),
              shape: const StadiumBorder(),
              child: InkWell(
                key: Key('reader.sheetTab.$i'),
                customBorder: const StadiumBorder(),
                onTap: () => onSelected(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.md - 2, vertical: Space.xs + 3),
                  child: Text(
                    names[i],
                    style: TextStyle(
                      color: on ? s.background : s.foreground,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
