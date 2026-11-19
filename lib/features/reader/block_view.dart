import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/reading_state.dart';
import '../../ui/design_system/tokens.dart';
import '../viewer/reflow_view.dart' show reflowColors;
import 'reader_model.dart';

/// A search hit: [length] characters at [start] of block [block]'s
/// [RBlock.searchText].
class ReaderHit {
  const ReaderHit(this.block, this.start, this.length);
  final int block, start, length;
  int get end => start + length;
}

const monospaceFamily = 'monospace';
const monospaceFallback = ['Menlo', 'Courier New', 'Courier', 'Roboto Mono'];

/// Colours and sizes of the reader page, derived from the page theme (real
/// background/foreground colours, no colour filter).
class ReaderStyle {
  const ReaderStyle({
    required this.theme,
    required this.background,
    required this.foreground,
    required this.muted,
    required this.link,
    required this.codeBackground,
    required this.border,
    required this.hit,
    required this.currentHit,
    required this.fontSize,
    required this.monospace,
  });

  factory ReaderStyle.of(PageTheme theme, {double fontScale = 1, bool monospace = false}) {
    final c = reflowColors(theme);
    final dark = theme == PageTheme.dark || theme == PageTheme.night;
    return ReaderStyle(
      theme: theme,
      background: c.background,
      foreground: c.text,
      muted: c.text.withValues(alpha: 0.65),
      link: switch (theme) {
        PageTheme.light => const Color(0xFF1F56C2),
        PageTheme.sepia => const Color(0xFF8A4B12),
        PageTheme.dark => const Color(0xFF8AB4F8),
        PageTheme.night => const Color(0xFFE0B36A),
      },
      codeBackground: c.text.withValues(alpha: dark ? 0.10 : 0.06),
      border: c.text.withValues(alpha: 0.22),
      hit: dark ? const Color(0x806B5B00) : const Color(0x80FFE066),
      currentHit: dark ? const Color(0xFFB36B00) : const Color(0xFFFFA94D),
      fontSize: (monospace ? 14.0 : 17.0) * fontScale,
      monospace: monospace,
    );
  }

  final PageTheme theme;
  final Color background, foreground, muted, link, codeBackground, border, hit, currentHit;
  final double fontSize;
  final bool monospace;

  TextStyle get body => TextStyle(
        color: foreground,
        fontSize: fontSize,
        height: monospace ? 1.4 : 1.55,
        fontFamily: monospace ? monospaceFamily : null,
        fontFamilyFallback: monospace ? monospaceFallback : null,
      );

  TextStyle get code => TextStyle(
        color: foreground,
        fontSize: fontSize * 0.88,
        height: 1.45,
        fontFamily: monospaceFamily,
        fontFamilyFallback: monospaceFallback,
      );

  TextStyle heading(int level) {
    const scale = [1.0, 1.75, 1.45, 1.25, 1.12, 1.04, 1.0];
    return body.copyWith(
      fontSize: fontSize * scale[level.clamp(1, 6)],
      height: 1.3,
      fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: level == 1 ? -0.3 : null,
    );
  }
}

/// Renders one [RBlock], highlighting [hits] (sorted, in this block) and
/// routing link taps to [onLink].
class ReaderBlockView extends StatefulWidget {
  const ReaderBlockView({
    super.key,
    required this.block,
    required this.style,
    this.hits = const [],
    this.currentHit,
    required this.onLink,
  });

  final RBlock block;
  final ReaderStyle style;
  final List<ReaderHit> hits;
  final ReaderHit? currentHit;
  final ValueChanged<String> onLink;

  @override
  State<ReaderBlockView> createState() => _ReaderBlockViewState();
}

class _ReaderBlockViewState extends State<ReaderBlockView> {
  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  ReaderStyle get s => widget.style;

  /// Builds spans for [spans] whose text starts at [base] in the block's
  /// search text.
  List<InlineSpan> _inline(List<RSpan> spans, int base, TextStyle style) {
    final out = <InlineSpan>[];
    var off = base;
    for (final r in spans) {
      if (r.imageAlt != null) {
        out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: ImagePlaceholderChip(alt: r.imageAlt!, style: s)));
        continue;
      }
      final decorations = <TextDecoration>[
        if (r.underline || r.link != null) TextDecoration.underline,
        if (r.strike) TextDecoration.lineThrough,
      ];
      var st = style.copyWith(
        fontWeight: r.bold ? FontWeight.w700 : null,
        fontStyle: r.italic ? FontStyle.italic : null,
        decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
        decorationColor: r.link != null ? s.link.withValues(alpha: 0.6) : null,
        color: r.link != null ? s.link : null,
      );
      if (r.code) {
        st = st.copyWith(
          fontFamily: monospaceFamily,
          fontFamilyFallback: monospaceFallback,
          fontSize: (style.fontSize ?? s.fontSize) * 0.9,
          backgroundColor: s.codeBackground,
        );
      }
      TapGestureRecognizer? rec;
      if (r.link case final link?) {
        rec = TapGestureRecognizer()..onTap = () => widget.onLink(link);
        _recognizers.add(rec);
      }
      final text = r.text;
      final len = text.length;
      var pos = 0;
      for (final h in widget.hits) {
        if (h.end <= off || h.start >= off + len) continue;
        final a = math.max(h.start - off, pos), b = math.min(h.end - off, len);
        if (a >= b) continue;
        if (a > pos) out.add(TextSpan(text: text.substring(pos, a), style: st, recognizer: rec));
        final color = identical(h, widget.currentHit) ? s.currentHit : s.hit;
        out.add(TextSpan(text: text.substring(a, b), style: st.copyWith(backgroundColor: color), recognizer: rec));
        pos = b;
      }
      if (pos < len) out.add(TextSpan(text: pos == 0 ? text : text.substring(pos), style: st, recognizer: rec));
      off += len;
    }
    return out;
  }

  Widget _rich(List<RSpan> spans, int base, TextStyle style, {TextAlign align = TextAlign.start}) =>
      Text.rich(TextSpan(style: style, children: _inline(spans, base, style)), textAlign: align);

  Widget _quote(int depth, Widget child) {
    if (depth <= 0) return child;
    return Container(
      margin: EdgeInsets.only(left: (depth - 1) * Space.md),
      padding: const EdgeInsets.only(left: Space.md - 2),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: s.border, width: 3))),
      child: DefaultTextStyle.merge(style: TextStyle(color: s.muted), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final b = widget.block;
    return switch (b) {
      TextBlock() => _text(b),
      LineBlock() => Padding(
          padding: EdgeInsets.only(top: b.gapBefore ? s.fontSize * 0.8 : 0),
          child: _rich([RSpan(b.text)], 0, s.body),
        ),
      CodeBlock() => _code(b),
      TableBlock() => _table(b),
      RuleBlock() => Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.md),
          child: Divider(color: s.border, height: 1, thickness: 1),
        ),
      PageBreakBlock() => Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.lg),
          child: Row(children: [
            Expanded(child: Divider(color: s.border)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.sm),
              child: Text('Page break', style: TextStyle(color: s.muted, fontSize: 11, letterSpacing: 0.6)),
            ),
            Expanded(child: Divider(color: s.border)),
          ]),
        ),
      ImageBlock() => _image(b),
    };
  }

  Widget _text(TextBlock b) {
    final level = b.headingLevel;
    final style = level > 0 ? s.heading(level) : s.body;
    Widget body = b.spans.isEmpty && b.marker == null
        ? SizedBox(height: s.fontSize * 0.6)
        : _rich(b.spans, 0, style);
    if (b.marker != null) {
      final checkbox = b.marker == '☐' || b.marker == '☑';
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: s.fontSize * (b.marker!.length > 2 ? 2.6 : 1.8),
            child: checkbox
                ? Icon(
                    b.marker == '☑' ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                    size: s.fontSize * 1.15,
                    color: s.muted,
                    semanticLabel: b.marker == '☑' ? 'Done' : 'Not done',
                  )
                : Text(b.marker!, style: s.body.copyWith(color: s.muted), textAlign: TextAlign.left),
          ),
          Expanded(child: body),
        ],
      );
    }
    final top = level > 0 ? s.fontSize * (level <= 2 ? 1.2 : 0.9) : (b.marker != null ? s.fontSize * 0.2 : s.fontSize * 0.5);
    final bottom = level > 0 ? s.fontSize * 0.35 : (b.marker != null ? 0.0 : s.fontSize * 0.25);
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom, left: b.indent * s.fontSize * 1.4),
      child: _quote(b.quoteDepth, body),
    );
  }

  Widget _code(CodeBlock b) {
    return Padding(
      padding: EdgeInsets.only(top: Space.sm, bottom: Space.sm, left: b.indent * s.fontSize * 1.4),
      child: _quote(
        b.quoteDepth,
        Container(
          width: double.infinity,
          decoration: BoxDecoration(color: s.codeBackground, borderRadius: const BorderRadius.all(Radius.circular(Radii.sm))),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(Space.md - 4),
            child: _rich([RSpan(b.text)], 0, s.code),
          ),
        ),
      ),
    );
  }

  Widget _table(TableBlock b) {
    final cols = b.columnCount;
    if (cols == 0) return const SizedBox.shrink();
    var off = 0;
    final rows = <TableRow>[];
    for (var r = 0; r < b.rows.length; r++) {
      final header = r < b.headerRows;
      final row = b.rows[r];
      final cells = <Widget>[];
      for (var c = 0; c < cols; c++) {
        final paras = c < row.length ? row[c] : const <List<RSpan>>[];
        final children = <Widget>[];
        for (final para in paras) {
          final style = header ? s.body.copyWith(fontWeight: FontWeight.w600) : s.body;
          children.add(_rich(para, off, style.copyWith(fontSize: s.fontSize * 0.92)));
          off += spansText(para).length + 1;
        }
        cells.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2, vertical: Space.sm - 2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
        ));
      }
      rows.add(TableRow(
        decoration: header ? BoxDecoration(color: s.codeBackground) : null,
        children: cells,
      ));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          border: TableBorder.all(color: s.border, borderRadius: const BorderRadius.all(Radius.circular(Radii.xs))),
          defaultColumnWidth: MinColumnWidth(const IntrinsicColumnWidth(), FixedColumnWidth(s.fontSize * 18)),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          children: rows,
        ),
      ),
    );
  }

  Widget _image(ImageBlock b) {
    final bytes = b.bytes;
    if (bytes == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        child: Align(alignment: Alignment.centerLeft, child: ImagePlaceholderChip(alt: b.alt, style: s)),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      child: LayoutBuilder(builder: (context, c) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 600.0;
        final natural = (b.width ?? maxW * dpr).toDouble();
        final cacheW = math.max(1, math.min(natural, math.min(maxW * dpr, 2048)).round());
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7, maxWidth: math.min(maxW, natural / dpr * 1.5)),
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(Radii.xs)),
              child: Image.memory(
                bytes,
                cacheWidth: cacheW,
                fit: BoxFit.contain,
                semanticLabel: b.alt.isEmpty ? 'Image' : b.alt,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => ImagePlaceholderChip(alt: b.alt, style: s),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Stand-in for an image that is not shown (never loaded from the network).
class ImagePlaceholderChip extends StatelessWidget {
  const ImagePlaceholderChip({super.key, required this.alt, required this.style});
  final String alt;
  final ReaderStyle style;

  @override
  Widget build(BuildContext context) {
    final label = alt.trim().isEmpty ? 'Image' : alt.trim();
    return Semantics(
      label: 'Image not shown: $label',
      excludeSemantics: true,
      child: Container(
        key: const Key('reader.imagePlaceholder'),
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xxs + 1),
        decoration: BoxDecoration(
          color: style.codeBackground,
          border: Border.all(color: style.border),
          borderRadius: Radii.pill,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_outlined, size: style.fontSize * 0.9, color: style.muted),
          const SizedBox(width: Space.xs),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: style.muted, fontSize: style.fontSize * 0.8)),
          ),
        ]),
      ),
    );
  }
}
