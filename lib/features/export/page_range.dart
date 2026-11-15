/// Parses page-range text such as `1-3, 5, 8-` into sorted, de-duplicated
/// 1-based page numbers.
///
/// Accepted syntax (spaces allowed around separators and dashes):
/// * `N` — a single page
/// * `A-B` — inclusive range (hyphen, en dash or em dash); `A` must be <= `B`
/// * `A-` — from `A` to the last page; `-B` — from page 1 to `B`
/// * items separated by `,` or `;`
class PageRangeParser {
  const PageRangeParser._();

  /// Upper bound on the input length; page-range text is typed by a person.
  static const int maxInputLength = 1000;

  static PageRangeResult parse(String input, int pageCount) {
    if (pageCount < 1) return const PageRangeResult.error('This document has no pages.');
    if (input.length > maxInputLength) return const PageRangeResult.error('Page range is too long.');
    final text = input.replaceAll(RegExp(r'[\u2013\u2014\u2212]'), '-').trim();
    if (text.isEmpty) return const PageRangeResult.error('Enter pages, e.g. 1-3, 5.');
    final pages = <int>{};
    for (final raw in text.split(RegExp('[,;]'))) {
      final part = raw.trim();
      if (part.isEmpty) continue; // tolerate "1,,2" and trailing commas
      final m = RegExp(r'^(\d*)\s*(-?)\s*(\d*)$').firstMatch(part);
      if (m == null) return PageRangeResult.error('"$part" is not a page or range.');
      final a = m.group(1)!, dash = m.group(2)!, b = m.group(3)!;
      if (dash.isEmpty) {
        if (b.isNotEmpty) return PageRangeResult.error('"$part" is not a page number.');
        final n = _num(a);
        if (n == null) return PageRangeResult.error('"$part" is not a page number.');
        if (n < 1 || n > pageCount) return PageRangeResult.error('Page $n does not exist (1–$pageCount).');
        pages.add(n);
        continue;
      }
      if (a.isEmpty && b.isEmpty) return PageRangeResult.error('"$part" is not a range.');
      final start = a.isEmpty ? 1 : _num(a);
      final end = b.isEmpty ? pageCount : _num(b);
      if (start == null || end == null) return PageRangeResult.error('"$part" is not a range.');
      if (start < 1 || start > pageCount) {
        return PageRangeResult.error('Page $start does not exist (1–$pageCount).');
      }
      if (end < 1 || end > pageCount) return PageRangeResult.error('Page $end does not exist (1–$pageCount).');
      if (start > end) return PageRangeResult.error('In "$part" the first page is after the last.');
      for (var i = start; i <= end; i++) {
        pages.add(i);
      }
    }
    if (pages.isEmpty) return const PageRangeResult.error('Enter pages, e.g. 1-3, 5.');
    return PageRangeResult.ok(pages.toList()..sort());
  }

  /// Formats pages compactly, e.g. [1,2,3,5] -> "1-3, 5".
  static String format(Iterable<int> pages) {
    final sorted = pages.toSet().toList()..sort();
    final parts = <String>[];
    var i = 0;
    while (i < sorted.length) {
      var j = i;
      while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
        j++;
      }
      parts.add(i == j ? '${sorted[i]}' : '${sorted[i]}-${sorted[j]}');
      i = j + 1;
    }
    return parts.join(', ');
  }

  static int? _num(String s) {
    if (s.isEmpty || s.length > 9) return s.isEmpty ? null : 1 << 30; // huge -> out of range
    return int.tryParse(s);
  }
}

class PageRangeResult {
  const PageRangeResult.ok(this.pages) : error = null;
  const PageRangeResult.error(this.error) : pages = const [];

  final List<int> pages;

  /// User-facing validation message; null when valid.
  final String? error;
  bool get isValid => error == null;
}
