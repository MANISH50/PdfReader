/// Parses split ranges such as `"1-3, 4, 7-"` into chunks of 1-based page
/// numbers. `"7-"` means 7 to the last page, `"-3"` means 1 to 3; ranges may
/// be descending (`"5-3"`). Throws [FormatException] with a user-readable
/// message on invalid input.
List<List<int>> parsePageRanges(String input, int pageCount) {
  final out = <List<int>>[];
  final parts = input.split(RegExp(r'[,;]')).map((s) => s.trim()).where((s) => s.isNotEmpty);
  for (final part in parts) {
    final m = RegExp(r'^(\d*)\s*(?:[-–]\s*(\d*))?$').firstMatch(part);
    if (m == null) throw FormatException('“$part” is not a page or range');
    final hasDash = part.contains(RegExp(r'[-–]'));
    final a = m[1]!.isEmpty ? (hasDash ? 1 : null) : int.tryParse(m[1]!);
    final b = !hasDash ? a : (m[2] == null || m[2]!.isEmpty ? pageCount : int.tryParse(m[2]!));
    if (a == null || b == null) throw FormatException('“$part” is not a page or range');
    for (final n in [a, b]) {
      if (n < 1 || n > pageCount) throw FormatException('Page $n is outside 1–$pageCount');
    }
    out.add([
      if (a <= b)
        for (var i = a; i <= b; i++) i
      else
        for (var i = a; i >= b; i--) i,
    ]);
  }
  if (out.isEmpty) throw const FormatException('Enter at least one page or range');
  return out;
}

/// "Every N pages" helper for the split dialog.
List<List<int>> chunkPages(int pageCount, int every) {
  if (every < 1) throw const FormatException('Chunk size must be at least 1');
  return [
    for (var s = 1; s <= pageCount; s += every)
      [for (var i = s; i < s + every && i <= pageCount; i++) i],
  ];
}

/// Compact label for a list of page numbers: [1,2,3,5] → "1-3, 5".
String describePages(List<int> pages) {
  if (pages.isEmpty) return '';
  final parts = <String>[];
  var start = pages.first, prev = pages.first;
  void flush() => parts.add(start == prev ? '$start' : '$start-$prev');
  for (final n in pages.skip(1)) {
    if (n == prev + 1) {
      prev = n;
      continue;
    }
    flush();
    start = prev = n;
  }
  flush();
  return parts.join(', ');
}
