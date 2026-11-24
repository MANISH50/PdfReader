import '../../core/documents/document_kind.dart';
import '../../core/security/limits.dart';
import 'reader_model.dart';

/// Caps for a delimited text file. Defaults: [SecurityLimits].
class SheetLimits {
  const SheetLimits({
    this.maxRows = SecurityLimits.maxSheetRows,
    this.maxColumns = SecurityLimits.maxSheetColumns,
    this.maxCells = SecurityLimits.maxSheetCells,
    this.maxCellChars = SecurityLimits.maxSheetCellChars,
    this.maxSheets = SecurityLimits.maxSheets,
  });
  final int maxRows, maxColumns, maxCells, maxCellChars, maxSheets;
}

/// Picks the delimiter for [text]: tab for `.tsv`/`.tab`, otherwise the most
/// consistent of `,` `;` tab `|` over the first lines (outside quotes).
String sniffDelimiter(String text, {String? extension}) {
  if (extension == '.tsv' || extension == '.tab') return '\t';
  const candidates = [',', ';', '\t', '|'];
  final sample = text.length > 16384 ? text.substring(0, 16384) : text;
  final lines = <String>[];
  var inQuotes = false;
  final cur = StringBuffer();
  for (var i = 0; i < sample.length && lines.length < 20; i++) {
    final c = sample[i];
    if (c == '"') inQuotes = !inQuotes;
    if (!inQuotes && (c == '\n' || c == '\r')) {
      if (cur.isNotEmpty) lines.add(cur.toString());
      cur.clear();
    } else if (!inQuotes) {
      cur.write(c);
    }
  }
  if (cur.isNotEmpty && lines.length < 20) lines.add(cur.toString());
  if (lines.isEmpty) return ',';
  var best = ',';
  var bestScore = 0.0;
  for (final d in candidates) {
    final counts = lines.map((l) => d.allMatches(l).length).toList();
    final first = counts.first;
    if (first == 0) continue;
    final consistent = counts.where((c) => c == first).length / counts.length;
    final score = consistent * 10 + first.clamp(0, 50) / 50;
    if (score > bestScore) {
      bestScore = score;
      best = d;
    }
  }
  return best;
}

/// Parses delimited text (RFC 4180: quoted fields, `""` escapes, line breaks
/// inside quotes, CRLF/LF/CR line endings) into a single sheet.
ReaderDocument parseDelimited(
  String text, {
  String name = 'Sheet1',
  String? extension,
  SheetLimits limits = const SheetLimits(),
  ParseBudget? budget,
}) {
  final delim = sniffDelimiter(text, extension: extension);
  final d = delim.codeUnitAt(0);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var fieldStarted = false;
  var cells = 0;
  var columns = 0;
  var truncated = false;
  var fieldOverflow = false;

  void endField() {
    if (row.length < limits.maxColumns) {
      final v = field.toString();
      row.add(v.length > limits.maxCellChars ? v.substring(0, limits.maxCellChars) : v);
    } else {
      truncated = true;
    }
    field.clear();
    fieldStarted = false;
    fieldOverflow = false;
  }

  bool endRow() {
    endField();
    // Drop a trailing empty line ("a,b\n" ends with one empty field).
    if (!(row.length == 1 && row.first.isEmpty)) {
      rows.add(row);
      cells += row.length;
      if (row.length > columns) columns = row.length;
    }
    row = <String>[];
    if (rows.length >= limits.maxRows || cells >= limits.maxCells) {
      truncated = true;
      return false;
    }
    return true;
  }

  final n = text.length;
  var i = 0;
  if (n > 0 && text.codeUnitAt(0) == 0xFEFF) i = 1;
  var stopped = false;
  for (; i < n; i++) {
    if ((i & 0xFFFF) == 0) budget?.check();
    final c = text.codeUnitAt(i);
    if (inQuotes) {
      if (c == 0x22) {
        if (i + 1 < n && text.codeUnitAt(i + 1) == 0x22) {
          if (!fieldOverflow) field.writeCharCode(0x22);
          i++;
        } else {
          inQuotes = false;
        }
      } else if (!fieldOverflow) {
        field.writeCharCode(c);
      }
    } else if (c == d) {
      endField();
    } else if (c == 0x0A || c == 0x0D) {
      if (c == 0x0D && i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
      if (!endRow()) {
        stopped = true;
        break;
      }
    } else if (c == 0x22 && !fieldStarted && field.isEmpty) {
      inQuotes = true;
      fieldStarted = true;
    } else if (!fieldOverflow) {
      field.writeCharCode(c);
      fieldStarted = true;
    }
    if (!fieldOverflow && field.length > limits.maxCellChars) {
      fieldOverflow = true;
      truncated = true;
    }
  }
  if (!stopped && (field.isNotEmpty || row.isNotEmpty || fieldStarted)) endRow();
  return ReaderDocument(
    kind: DocumentKind.sheet,
    sheets: [SheetData(name: name, rows: rows, columnCount: columns, truncated: truncated)],
  );
}
