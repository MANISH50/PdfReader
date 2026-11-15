import 'dart:math' as math;

/// Pure layout analysis used by the DOCX exporter: turns positioned
/// characters of one page into paragraphs with styled runs, then classifies
/// headings across the whole document by relative font size.
///
/// Coordinates are PDF page points with the origin at the bottom-left
/// (y grows upwards), as returned by pdfrx.

class CharBox {
  const CharBox(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;
  double get width => right - left;
  double get height => top - bottom;
  bool get isEmpty => width <= 0 && height <= 0;
}

/// Per-character font information, when the engine can provide it.
class CharStyle {
  const CharStyle({this.fontSize, this.bold = false, this.italic = false});
  final double? fontSize;
  final bool bold;
  final bool italic;
}

class PageChar {
  const PageChar(this.text, this.box, [this.style]);

  /// One user-perceived code point (may be a surrogate pair).
  final String text;
  final CharBox? box;
  final CharStyle? style;

  bool get isSpace => text.trim().isEmpty;
}

class TextRun {
  TextRun(this.text, {this.bold = false, this.italic = false});
  String text;
  final bool bold;
  final bool italic;
}

enum BlockKind { paragraph, heading1, heading2, heading3 }

class TextParagraph {
  TextParagraph({required this.runs, required this.fontSize, required this.rtl, required this.lineCount});

  final List<TextRun> runs;

  /// Estimated font size in points (median of the paragraph's lines).
  final double fontSize;
  final bool rtl;
  final int lineCount;
  BlockKind kind = BlockKind.paragraph;

  String get text => runs.map((r) => r.text).join();
  bool get allBold => runs.where((r) => r.text.trim().isNotEmpty).every((r) => r.bold);
  int get charCount => text.length;
}

/// A line as found in the engine's text stream.
class _Line {
  _Line(this.chars);
  final List<PageChar> chars;
  late final String text = chars.map((c) => c.text).join().trimRight();
  late final List<PageChar> _visible = [for (final c in chars) if (!c.isSpace && c.box != null && !c.box!.isEmpty) c];
  bool get hasGeometry => _visible.isNotEmpty;
  late final double left = _visible.isEmpty ? 0 : _visible.map((c) => c.box!.left).reduce(math.min);
  late final double right = _visible.isEmpty ? 0 : _visible.map((c) => c.box!.right).reduce(math.max);
  late final double top = _visible.isEmpty ? 0 : _visible.map((c) => c.box!.top).reduce(math.max);
  late final double bottom = _visible.isEmpty ? 0 : _visible.map((c) => c.box!.bottom).reduce(math.min);

  /// Glyph-box height of the line, a proxy for the font size.
  late final double height = _visible.isEmpty ? 0 : math.max(top - bottom, 0.1);

  /// Font size: engine-reported median when plausible, else box height.
  late final double size = () {
    final sizes = [
      for (final c in chars)
        if (!c.isSpace && c.style?.fontSize != null && c.style!.fontSize! >= 2) c.style!.fontSize!
    ]..sort();
    if (sizes.isNotEmpty) {
      final s = sizes[sizes.length ~/ 2];
      // Fonts set at 1pt and scaled by the text matrix report tiny sizes; trust the boxes then.
      if (!hasGeometry || (height / s > 0.3 && height / s < 3)) return s;
    }
    return hasGeometry ? height : 0.0;
  }();

  late final bool rtl = isRtlText(text);
}

/// True when the majority of strong directional letters are Hebrew/Arabic
/// (or other RTL scripts).
bool isRtlText(String text) {
  var rtl = 0, ltr = 0;
  for (final r in text.runes) {
    if (_isRtlRune(r)) {
      rtl++;
    } else if (_isStrongLtr(r)) {
      ltr++;
    }
  }
  return rtl > 0 && rtl >= ltr;
}

bool _isRtlRune(int r) =>
    (r >= 0x0590 && r <= 0x08FF) || // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic ext.
    (r >= 0xFB1D && r <= 0xFDFF) || // Hebrew/Arabic presentation forms A
    (r >= 0xFE70 && r <= 0xFEFF) || // Arabic presentation forms B
    (r >= 0x10800 && r <= 0x10FFF) ||
    (r >= 0x1E800 && r <= 0x1EFFF);

bool _isStrongLtr(int r) =>
    (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) || (r >= 0xC0 && r < 0x0590) || (r >= 0x0900 && r < 0xFB1D);

final _listStart = RegExp(r'^\s*([•◦▪●‣⁃∙\-\*–]\s|\(?\d{1,3}[.)]\s|\(?[a-zA-Z][.)]\s)');

/// Splits engine text into [PageChar]s. pdfium reports one box per char
/// index; this aligns by UTF-16 unit when the counts match, otherwise by
/// code point, otherwise without geometry.
List<PageChar> buildPageChars(String text, List<CharBox?> boxes, [List<CharStyle?>? styles]) {
  CharStyle? st(int i) => styles != null && i < styles.length ? styles[i] : null;
  if (text.length == boxes.length) {
    final out = <PageChar>[];
    for (var i = 0; i < text.length; i++) {
      final u = text.codeUnitAt(i);
      // Keep surrogate pairs together; the low half's box is dropped.
      if (u >= 0xD800 && u <= 0xDBFF && i + 1 < text.length) {
        out.add(PageChar(text.substring(i, i + 2), boxes[i], st(i)));
        i++;
      } else {
        out.add(PageChar(text[i], boxes[i], st(i)));
      }
    }
    return out;
  }
  final runes = text.runes.toList();
  if (runes.length == boxes.length) {
    return [for (var i = 0; i < runes.length; i++) PageChar(String.fromCharCode(runes[i]), boxes[i], st(i))];
  }
  return [for (final r in runes) PageChar(String.fromCharCode(r), null)];
}

/// Groups one page's characters into paragraphs.
List<TextParagraph> analyzePage(List<PageChar> chars) {
  final lines = <_Line>[];
  var cur = <PageChar>[];
  for (final c in chars) {
    if (c.text == '\r') continue;
    if (c.text == '\n') {
      lines.add(_Line(cur));
      cur = [];
    } else {
      cur.add(c);
    }
  }
  lines.add(_Line(cur));

  final paragraphs = <TextParagraph>[];
  var group = <_Line>[];
  double? firstGap;
  var blockLeft = 0.0, blockRight = 0.0; // running extent of [group]

  void flush() {
    if (group.isNotEmpty) paragraphs.add(_toParagraph(group));
    group = [];
    firstGap = null;
  }

  void add(_Line line) {
    if (group.isEmpty) {
      blockLeft = line.left;
      blockRight = line.right;
    } else {
      blockLeft = math.min(blockLeft, line.left);
      blockRight = math.max(blockRight, line.right);
    }
    group.add(line);
  }

  for (final line in lines) {
    if (line.text.trim().isEmpty) {
      flush();
      continue;
    }
    if (group.isEmpty) {
      add(line);
      continue;
    }
    final prev = group.last;
    final (brk, gap) = _breaksBefore(prev, line, group.length, blockLeft, blockRight, firstGap);
    if (brk) {
      flush();
    } else if (gap != null) {
      firstGap ??= gap;
    }
    add(line);
  }
  flush();
  return paragraphs;
}

(bool, double?) _breaksBefore(
    _Line prev, _Line cur, int groupLength, double blockLeft, double blockRight, double? firstGap) {
  if (prev.rtl != cur.rtl) return (true, null);
  if (_listStart.hasMatch(cur.text)) return (true, null);
  if (!prev.hasGeometry || !cur.hasGeometry) return (false, null);
  final h = math.max(prev.height, cur.height);
  final sizeA = prev.size, sizeB = cur.size;
  if (sizeA > 0 && sizeB > 0 && (sizeA - sizeB).abs() / math.max(sizeA, sizeB) > 0.15) return (true, null);
  // Next line is not below the previous one: column change or out-of-order text.
  if (cur.top > prev.bottom + 0.2 * h && cur.bottom > prev.bottom - 0.2 * h) return (true, null);
  final gap = prev.bottom - cur.top;
  if (firstGap == null) {
    if (gap > 0.8 * h) return (true, null);
  } else if (gap > firstGap * 1.3 + 0.2 * h) {
    return (true, null);
  }
  // No horizontal overlap: separate columns or blocks.
  if (cur.left > prev.right || cur.right < prev.left) return (true, null);
  if (!cur.rtl) {
    // New indented first line, or the previous line ended early.
    if (cur.left > blockLeft + 1.0 * h && groupLength > 1) return (true, null);
    if (groupLength > 1 && prev.right < blockRight - 4 * h) return (true, null);
  } else {
    if (cur.right < blockRight - 1.0 * h && groupLength > 1) return (true, null);
    if (groupLength > 1 && prev.left > blockLeft + 4 * h) return (true, null);
  }
  return (false, gap);
}

TextParagraph _toParagraph(List<_Line> lines) {
  final runs = <TextRun>[];
  void add(String text, CharStyle? style) {
    final bold = style?.bold ?? false, italic = style?.italic ?? false;
    if (runs.isNotEmpty && (text.trim().isEmpty || (runs.last.bold == bold && runs.last.italic == italic))) {
      runs.last.text += text;
    } else {
      runs.add(TextRun(text, bold: bold, italic: italic));
    }
  }

  for (var li = 0; li < lines.length; li++) {
    final chars = lines[li].chars;
    var end = chars.length;
    while (end > 0 && chars[end - 1].isSpace) {
      end--;
    }
    var start = 0;
    if (li > 0) {
      while (start < end && chars[start].isSpace) {
        start++;
      }
    }
    for (var i = start; i < end; i++) {
      add(chars[i].text, chars[i].isSpace ? null : chars[i].style);
    }
    if (li + 1 < lines.length && runs.isNotEmpty) {
      final last = runs.last;
      // De-hyphenate words broken across lines ("exam-" + "ple").
      final next = lines[li + 1].text.trimLeft();
      if (last.text.endsWith('-') &&
          last.text.length > 1 &&
          _isLetter(last.text.codeUnitAt(last.text.length - 2)) &&
          next.isNotEmpty &&
          _isLower(next.codeUnitAt(0))) {
        last.text = last.text.substring(0, last.text.length - 1);
      } else {
        last.text += ' ';
      }
    }
  }
  final sizes = [for (final l in lines) if (l.size > 0) l.size]..sort();
  return TextParagraph(
    runs: runs,
    fontSize: sizes.isEmpty ? 0 : sizes[sizes.length ~/ 2],
    rtl: isRtlText(lines.map((l) => l.text).join(' ')),
    lineCount: lines.length,
  );
}

bool _isLetter(int u) => (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || (u >= 0xC0 && u <= 0x24F);
bool _isLower(int u) => (u >= 0x61 && u <= 0x7A) || (u >= 0xDF && u <= 0xFF);

/// Most common font size across the document, weighted by characters,
/// rounded to 0.5pt. Returns 0 when nothing has a size.
double bodyFontSize(Iterable<TextParagraph> paragraphs) {
  final weights = <double, int>{};
  for (final p in paragraphs) {
    if (p.fontSize <= 0) continue;
    final k = (p.fontSize * 2).round() / 2;
    weights[k] = (weights[k] ?? 0) + p.charCount;
  }
  if (weights.isEmpty) return 0;
  return weights.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key < a.key) ? b : a).key;
}

/// Marks headings by font size relative to the body size.
void classifyHeadings(List<List<TextParagraph>> pages) {
  final body = bodyFontSize(pages.expand((p) => p));
  if (body <= 0) return;
  for (final page in pages) {
    for (final p in page) {
      final text = p.text.trim();
      if (text.isEmpty || text.length > 200 || p.lineCount > 3 || p.fontSize <= 0) continue;
      final ratio = p.fontSize / body;
      if (ratio >= 1.6) {
        p.kind = BlockKind.heading1;
      } else if (ratio >= 1.3) {
        p.kind = BlockKind.heading2;
      } else if (ratio >= 1.12 || (ratio >= 1.05 && p.allBold && text.length <= 100)) {
        p.kind = BlockKind.heading3;
      }
    }
  }
}
