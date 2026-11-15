import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/features/export/docx/layout.dart';

/// Lays out [lines] top-down as PageChars, one box per character.
/// Each line: (text, fontSize, left, bold, italic). Line pitch = 1.2 * size,
/// plus [extraGap] before lines whose index is in [gapBefore].
List<PageChar> typeset(
  List<(String, double, double, bool, bool)> lines, {
  Set<int> gapBefore = const {},
  double top = 800,
  bool withStyles = true,
  bool rtl = false,
}) {
  final out = <PageChar>[];
  var y = top;
  for (var i = 0; i < lines.length; i++) {
    final (text, size, left, bold, italic) = lines[i];
    if (gapBefore.contains(i)) y -= size * 1.5;
    final cw = size * 0.5;
    final runes = text.runes.toList();
    for (var j = 0; j < runes.length; j++) {
      final x = rtl ? left + (runes.length - j - 1) * cw : left + j * cw;
      final ch = String.fromCharCode(runes[j]);
      out.add(PageChar(
        ch,
        CharBox(x, y, x + cw, y - size * 0.9),
        withStyles && ch.trim().isNotEmpty ? CharStyle(fontSize: size, bold: bold, italic: italic) : null,
      ));
    }
    if (i + 1 < lines.length) {
      out.add(const PageChar('\r', CharBox(0, 0, 0, 0)));
      out.add(const PageChar('\n', CharBox(0, 0, 0, 0)));
    }
    y -= size * 1.2;
  }
  return out;
}

void main() {
  // Full-width line ~ 90 chars at 11pt ≈ 495pt wide.
  final full = 'word ' * 18;

  test('joins wrapped lines into one paragraph and splits on vertical gaps', () {
    final chars = typeset([
      (full, 11, 50, false, false),
      (full, 11, 50, false, false),
      ('end of first.', 11, 50, false, false),
      (full, 11, 50, false, false),
      ('end of second.', 11, 50, false, false),
    ], gapBefore: {3});
    final ps = analyzePage(chars);
    expect(ps, hasLength(2));
    expect(ps[0].lineCount, 3);
    expect(ps[0].text, endsWith('end of first.'));
    expect(ps[0].text, isNot(contains('\n')));
    expect(ps[1].text, endsWith('end of second.'));
  });

  test('short last line ends a paragraph even without a gap', () {
    final ps = analyzePage(typeset([
      (full, 11, 50, false, false),
      ('short.', 11, 50, false, false),
      (full, 11, 50, false, false),
      (full, 11, 50, false, false),
    ]));
    // "short." is the last line of paragraph 1 only if the next line is
    // separated; the rule triggers on the line *after* a short line.
    expect(ps.length, 2);
    expect(ps[0].text.trim(), endsWith('short.'));
  });

  test('font size change splits and headings are classified', () {
    final page = analyzePage(typeset([
      ('Big Title', 24, 50, true, false),
      ('Sub heading', 15, 50, true, false),
      (full, 11, 50, false, false),
      ('last line.', 11, 50, false, false),
    ]));
    expect(page, hasLength(3));
    classifyHeadings([page]);
    expect(page[0].kind, BlockKind.heading1);
    expect(page[1].kind, BlockKind.heading2);
    expect(page[2].kind, BlockKind.paragraph);
    expect(bodyFontSize(page), 11);
  });

  test('bold and italic runs are preserved', () {
    final chars = <PageChar>[
      ...typeset([('Normal ', 11, 50, false, false)]),
      ...typeset([('bold', 11, 85, true, false)]),
      ...typeset([(' and ', 11, 105, false, false)]),
      ...typeset([('italic', 11, 130, false, true)]),
    ];
    final p = analyzePage(chars).single;
    expect(p.text, 'Normal bold and italic');
    final bold = p.runs.where((r) => r.bold).map((r) => r.text.trim()).toList();
    final italic = p.runs.where((r) => r.italic).map((r) => r.text.trim()).toList();
    expect(bold, ['bold']);
    expect(italic, ['italic']);
  });

  test('works without engine styles (box heights as size)', () {
    final page = analyzePage(typeset([
      ('Heading', 22, 50, false, false),
      (full, 10, 50, false, false),
      ('tail.', 10, 50, false, false),
    ], withStyles: false));
    classifyHeadings([page]);
    expect(page.first.kind, BlockKind.heading1);
    expect(page.last.kind, BlockKind.paragraph);
  });

  test('de-hyphenates words split across lines', () {
    final p = analyzePage(typeset([
      ('${'word ' * 17}exam-', 11, 50, false, false),
      ('ple text.', 11, 50, false, false),
    ])).single;
    expect(p.text, contains('example text.'));
  });

  test('list items start new paragraphs', () {
    final ps = analyzePage(typeset([
      ('• first item', 11, 50, false, false),
      ('• second item', 11, 50, false, false),
      ('1. numbered', 11, 50, false, false),
    ]));
    expect(ps.map((p) => p.text).toList(), ['• first item', '• second item', '1. numbered']);
  });

  test('RTL Hebrew and Arabic detected, Unicode kept', () {
    const hebrew = 'שלום עולם';
    const arabic = 'مرحبا بالعالم';
    final ps = analyzePage(typeset([
      (hebrew, 11, 300, false, false),
      (arabic, 11, 300, false, false),
    ], rtl: true, gapBefore: {1}));
    expect(ps.map((p) => p.text).toList(), [hebrew, arabic]);
    expect(ps.every((p) => p.rtl), isTrue);
  });

  test('Hindi stays LTR and intact', () {
    const hindi = 'नमस्ते दुनिया';
    final p = analyzePage(typeset([(hindi, 11, 50, false, false)])).single;
    expect(p.text, hindi);
    expect(p.rtl, isFalse);
  });

  test('isRtlText', () {
    expect(isRtlText('hello'), isFalse);
    expect(isRtlText('שלום'), isTrue);
    expect(isRtlText('123'), isFalse);
    expect(isRtlText('A long English sentence with one word שלום'), isFalse);
  });

  group('buildPageChars', () {
    const box = CharBox(0, 10, 5, 0);
    test('aligns by code unit', () {
      final cs = buildPageChars('ab', [box, box]);
      expect(cs.map((c) => c.text), ['a', 'b']);
      expect(cs.every((c) => c.box != null), isTrue);
    });
    test('keeps surrogate pairs', () {
      final cs = buildPageChars('a😀', [box, box, box]);
      expect(cs.map((c) => c.text), ['a', '😀']);
    });
    test('aligns by rune when counts match runes', () {
      final cs = buildPageChars('a😀', [box, box]);
      expect(cs.map((c) => c.text), ['a', '😀']);
      expect(cs.last.box, isNotNull);
    });
    test('drops geometry on mismatch', () {
      final cs = buildPageChars('abc', [box]);
      expect(cs.every((c) => c.box == null), isTrue);
      expect(analyzePage(cs).single.text, 'abc');
    });
  });

  test('empty page gives no paragraphs', () {
    expect(analyzePage(const []), isEmpty);
    expect(analyzePage([const PageChar(' ', null)]), isEmpty);
  });

  test('columns: text that jumps back up starts a new paragraph', () {
    final left = typeset([(full, 11, 50, false, false), (full, 11, 50, false, false)]);
    final right = typeset([(full, 11, 600, false, false)], top: 800);
    final ps = analyzePage([...left, const PageChar('\n', null), ...right]);
    expect(ps, hasLength(2));
  });
}
