/// Text-box layout shared by the on-screen painter and the PDF flattener so
/// that line breaks match. Uses the standard Helvetica metrics (the font the
/// flattener writes with, which every PDF viewer has built in).
library;

const List<int> _helveticaAscii = [
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, // 32-47
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 48-63
  1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // 64-79
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // 80-95
  333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // 96-111
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, // 112-126
];

const double kTextBoxLineHeight = 1.2;
const double kTextBoxPadding = 2;

double helveticaWidth(String s, double fontSize) {
  var w = 0;
  for (final c in s.runes) {
    w += (c >= 32 && c <= 126) ? _helveticaAscii[c - 32] : 556;
  }
  return w * fontSize / 1000;
}

/// True if [s] can be written with a standard-14 font (WinAnsi encoding).
bool isWinAnsiEncodable(String s) {
  const extra = {0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039,
    0x0152, 0x017D, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161,
    0x203A, 0x0153, 0x017E, 0x0178};
  for (final c in s.runes) {
    if (c == 10 || c == 13 || c == 9) continue;
    if ((c >= 0x20 && c <= 0x7E) || (c >= 0xA0 && c <= 0xFF) || extra.contains(c)) continue;
    return false;
  }
  return true;
}

/// Greedy word wrap of [text] into lines no wider than [maxWidth] points.
/// Explicit newlines are kept; over-long words are broken by characters.
List<String> wrapText(String text, double fontSize, double maxWidth) {
  final lines = <String>[];
  for (final para in text.replaceAll('\r\n', '\n').split('\n')) {
    final words = para.split(' ');
    var cur = '';
    for (final word in words) {
      final cand = cur.isEmpty ? word : '$cur $word';
      if (helveticaWidth(cand, fontSize) <= maxWidth || cur.isEmpty && helveticaWidth(word, fontSize) <= maxWidth) {
        cur = cand;
        continue;
      }
      if (cur.isNotEmpty) lines.add(cur);
      cur = '';
      if (helveticaWidth(word, fontSize) <= maxWidth) {
        cur = word;
        continue;
      }
      // Break a long word.
      var chunk = '';
      for (final ch in word.split('')) {
        if (chunk.isNotEmpty && helveticaWidth(chunk + ch, fontSize) > maxWidth) {
          lines.add(chunk);
          chunk = '';
        }
        chunk += ch;
      }
      cur = chunk;
    }
    lines.add(cur);
  }
  return lines;
}
