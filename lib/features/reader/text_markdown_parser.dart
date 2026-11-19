import 'dart:typed_data';

import 'package:markdown/markdown.dart' as md;

import '../../core/documents/document_kind.dart';
import 'reader_model.dart';

/// Longest line kept as one list item; longer lines (minified JSON, logs)
/// are split so a single item never lays out megabytes of text.
const int kMaxLineChars = 2000;

/// Lines of proportional text grouped into one list item at most.
const int _maxParagraphLines = 40;

/// Decodes text-file bytes (UTF-8, optional BOM, or UTF-16 with BOM).
String decodeTextFile(Uint8List bytes) => decodeText(bytes, lenient: true) ?? '';

String _normalizeNewlines(String s) => s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

Iterable<String> _chunks(String line) sync* {
  if (line.length <= kMaxLineChars) {
    yield line;
    return;
  }
  for (var i = 0; i < line.length; i += kMaxLineChars) {
    var end = i + kMaxLineChars;
    if (end > line.length) end = line.length;
    // Don't split a surrogate pair.
    if (end < line.length && (line.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
    yield line.substring(i, end);
    if (end != i + kMaxLineChars) i = end - kMaxLineChars;
  }
}

/// Plain text → lines (monospace) or paragraphs of lines (proportional).
ReaderDocument parsePlainText(String text, {required bool monospace, ParseBudget? budget}) {
  final lines = _normalizeNewlines(text).split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final blocks = <RBlock>[];
  var n = 0;
  if (monospace) {
    for (final line in lines) {
      if (++n % 8192 == 0) budget?.check();
      for (final c in _chunks(line)) {
        blocks.add(LineBlock(c));
      }
    }
  } else {
    final para = <String>[];
    var gap = false;
    void flush() {
      if (para.isEmpty) return;
      blocks.add(LineBlock(para.join('\n'), gapBefore: gap));
      para.clear();
      gap = false;
    }

    for (final line in lines) {
      if (++n % 8192 == 0) budget?.check();
      if (line.trim().isEmpty) {
        flush();
        gap = blocks.isNotEmpty;
        continue;
      }
      if (line.length > kMaxLineChars) {
        flush();
        for (final c in _chunks(line)) {
          blocks.add(LineBlock(c));
        }
        continue;
      }
      para.add(line);
      if (para.length >= _maxParagraphLines) flush(); // continues without a gap
    }
    flush();
  }
  return ReaderDocument(kind: DocumentKind.text, blocks: blocks, monospace: monospace);
}

// ---- Markdown -------------------------------------------------------------

/// Markdown → blocks via the `markdown` package AST (GitHub flavour). Raw HTML
/// is kept as literal text; images become placeholders (never loaded).
ReaderDocument parseMarkdown(String text, {ParseBudget? budget}) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(_normalizeNewlines(text));
  budget?.check();
  final out = <RBlock>[];
  _MdConverter(out, budget).blocks(nodes, indent: 0, quote: 0);
  return ReaderDocument(kind: DocumentKind.markdown, blocks: out);
}

const _blockTags = {
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'pre', 'blockquote', 'table', 'hr', 'section', 'div',
  'details', 'summary', 'li', 'dl', 'dt', 'dd', 'figure',
};

class _Style {
  const _Style({this.bold = false, this.italic = false, this.strike = false, this.code = false, this.link});
  final bool bold, italic, strike, code;
  final String? link;
  _Style copy({bool? bold, bool? italic, bool? strike, bool? code, String? link}) => _Style(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        strike: strike ?? this.strike,
        code: code ?? this.code,
        link: link ?? this.link,
      );
}

class _MdConverter {
  _MdConverter(this.out, this.budget);
  final List<RBlock> out;
  final ParseBudget? budget;
  int _n = 0;

  void blocks(List<md.Node> nodes, {required int indent, required int quote}) {
    final pending = <md.Node>[];
    void flushInline() {
      if (pending.isEmpty) return;
      final spans = inline(pending);
      pending.clear();
      if (spansText(spans).trim().isNotEmpty || spans.any((s) => s.imageAlt != null)) {
        out.add(TextBlock(spans, indent: indent, quoteDepth: quote));
      }
    }

    for (final node in nodes) {
      if (++_n % 2048 == 0) budget?.check();
      if (node is md.Element && _blockTags.contains(node.tag)) {
        flushInline();
        block(node, indent: indent, quote: quote);
      } else {
        pending.add(node);
      }
    }
    flushInline();
  }

  void block(md.Element e, {required int indent, required int quote}) {
    final children = e.children ?? const <md.Node>[];
    switch (e.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        out.add(TextBlock(inline(children), headingLevel: int.parse(e.tag.substring(1)), indent: indent, quoteDepth: quote));
      case 'p' || 'dt' || 'summary':
        out.add(TextBlock(inline(children), indent: indent, quoteDepth: quote));
      case 'blockquote':
        blocks(children, indent: indent, quote: quote + 1);
      case 'hr':
        out.add(const RuleBlock());
      case 'pre':
        final code = children.whereType<md.Element>().where((c) => c.tag == 'code').firstOrNull;
        final cls = code?.attributes['class'] ?? '';
        final lang = cls.startsWith('language-') ? cls.substring(9) : null;
        var t = (code ?? e).textContent;
        if (t.endsWith('\n')) t = t.substring(0, t.length - 1);
        out.add(CodeBlock(t, language: lang, indent: indent, quoteDepth: quote));
      case 'ul' || 'ol':
        _list(e, indent: indent, quote: quote);
      case 'table':
        _table(e);
      case 'dd':
        blocks(children, indent: indent + 1, quote: quote);
      default: // section (footnotes), div, details, li outside a list, dl, figure
        blocks(children, indent: indent, quote: quote);
    }
  }

  void _list(md.Element list, {required int indent, required int quote}) {
    final ordered = list.tag == 'ol';
    var number = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    for (final li in (list.children ?? const <md.Node>[]).whereType<md.Element>()) {
      if (li.tag != 'li') continue;
      var children = List<md.Node>.of(li.children ?? const <md.Node>[]);
      String marker = ordered ? '$number.' : (indent % 3 == 0 ? '•' : indent % 3 == 1 ? '◦' : '▪');
      number++;
      // GFM task list: a checkbox input first (possibly inside the first <p>).
      md.Element? box;
      if (children.isNotEmpty && children.first is md.Element) {
        final first = children.first as md.Element;
        if (first.tag == 'input') {
          box = first;
          children = children.sublist(1);
        } else if (first.tag == 'p' && first.children?.firstOrNull is md.Element &&
            (first.children!.first as md.Element).tag == 'input') {
          box = first.children!.first as md.Element;
          children = [md.Element(first.tag, first.children!.sublist(1)), ...children.skip(1)];
        }
      }
      if (box != null) marker = box.attributes.containsKey('checked') ? '☑' : '☐';

      var markerUsed = false;
      final pending = <md.Node>[];
      void flush() {
        if (pending.isEmpty) return;
        out.add(TextBlock(inline(pending), marker: markerUsed ? null : marker, indent: indent, quoteDepth: quote));
        markerUsed = true;
        pending.clear();
      }

      for (final c in children) {
        if (c is md.Element && _blockTags.contains(c.tag)) {
          flush();
          if (c.tag == 'p' && !markerUsed) {
            out.add(TextBlock(inline(c.children ?? const []), marker: marker, indent: indent, quoteDepth: quote));
            markerUsed = true;
          } else if (c.tag == 'p') {
            out.add(TextBlock(inline(c.children ?? const []), indent: indent + 1, quoteDepth: quote));
          } else {
            if (!markerUsed) {
              out.add(TextBlock(const [], marker: marker, indent: indent, quoteDepth: quote));
              markerUsed = true;
            }
            block(c, indent: indent + 1, quote: quote);
          }
        } else {
          pending.add(c);
        }
      }
      flush();
      if (!markerUsed) out.add(TextBlock(const [], marker: marker, indent: indent, quoteDepth: quote));
    }
  }

  void _table(md.Element table) {
    final rows = <List<List<List<RSpan>>>>[];
    var header = 0;
    for (final section in (table.children ?? const <md.Node>[]).whereType<md.Element>()) {
      final trs = section.tag == 'tr' ? [section] : (section.children ?? const <md.Node>[]).whereType<md.Element>();
      for (final tr in trs) {
        if (tr.tag != 'tr') continue;
        if (section.tag == 'thead') header++;
        rows.add([
          for (final cell in (tr.children ?? const <md.Node>[]).whereType<md.Element>())
            [inline(cell.children ?? const [], base: _Style(bold: cell.tag == 'th'))],
        ]);
      }
    }
    if (rows.isNotEmpty) out.add(TableBlock(rows, headerRows: header));
  }

  List<RSpan> inline(List<md.Node> nodes, {_Style base = const _Style()}) {
    final spans = <RSpan>[];
    void walk(md.Node n, _Style s) {
      if (n is md.Text) {
        if (n.text.isNotEmpty) {
          spans.add(RSpan(n.text, bold: s.bold, italic: s.italic, strike: s.strike, code: s.code, link: s.link));
        }
        return;
      }
      if (n is md.UnparsedContent) {
        spans.add(RSpan(n.textContent, bold: s.bold, italic: s.italic, link: s.link));
        return;
      }
      if (n is! md.Element) return;
      final kids = n.children ?? const <md.Node>[];
      switch (n.tag) {
        case 'strong' || 'b':
          for (final k in kids) {
            walk(k, s.copy(bold: true));
          }
        case 'em' || 'i':
          for (final k in kids) {
            walk(k, s.copy(italic: true));
          }
        case 'del' || 's':
          for (final k in kids) {
            walk(k, s.copy(strike: true));
          }
        case 'code':
          spans.add(RSpan(n.textContent, code: true, bold: s.bold, italic: s.italic, link: s.link));
        case 'a':
          final href = n.attributes['href'];
          for (final k in kids) {
            walk(k, s.copy(link: href ?? s.link));
          }
        case 'img':
          // Never fetched: remote, data: and relative images are all placeholders.
          spans.add(RSpan.image(n.attributes['alt'] ?? ''));
        case 'br':
          spans.add(RSpan('\n', bold: s.bold, italic: s.italic));
        case 'input':
          spans.add(RSpan(n.attributes.containsKey('checked') ? '☑ ' : '☐ '));
        default:
          for (final k in kids) {
            walk(k, s);
          }
      }
    }

    for (final n in nodes) {
      walk(n, base);
    }
    // Trim the paragraph's outer whitespace (soft line breaks at the ends).
    if (spans.isNotEmpty && spans.first.imageAlt == null) {
      spans[0] = spans.first.withText(spans.first.text.replaceFirst(RegExp(r'^\s+'), ''));
    }
    if (spans.isNotEmpty && spans.last.imageAlt == null) {
      spans[spans.length - 1] = spans.last.withText(spans.last.text.replaceFirst(RegExp(r'\s+$'), ''));
    }
    spans.removeWhere((s) => s.text.isEmpty && s.imageAlt == null);
    return spans;
  }
}

/// Anchor slug for a heading, GitHub style ("My Title!" → "my-title").
String headingSlug(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}\s_-]', unicode: true), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), '-');
