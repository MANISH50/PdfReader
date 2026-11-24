import 'dart:io' as io;
import 'dart:typed_data';

import 'package:xml/xml_events.dart';

import '../../core/documents/document_kind.dart';
import '../../core/security/limits.dart';
import 'csv_parser.dart';
import 'reader_model.dart';
import 'safe_zip.dart';

/// Shown above every Excel workbook in the reader.
const xlsxNotice = 'Showing cell values only. Formulas show their last saved result; '
    'dates may show as numbers. Charts and pictures are not shown.';

/// Parses an Excel workbook (.xlsx) into sheets of plain cell values.
///
/// Uses the same hardened ZIP reader as DOCX ([SafeZip]): entry-count and
/// path checks, no encrypted entries, capped inflation, DOCTYPEs dropped.
/// Only the workbook, its relationships, shared strings and worksheets are
/// read; macros (vbaProject.bin), external links, charts and images never
/// are.
ReaderDocument parseXlsx(
  Uint8List bytes, {
  DocxLimits zipLimits = const DocxLimits(),
  SheetLimits limits = const SheetLimits(),
  ParseBudget? budget,
}) {
  try {
    final zip = SafeZip(bytes, zipLimits, budget);
    final workbook = zip.readText('xl/workbook.xml', zipLimits.maxXmlBytes);
    if (workbook == null) throw const ReaderOpenException(ReaderFailure.damaged);
    final rels = parseRels(zip.readText('xl/_rels/workbook.xml.rels', zipLimits.maxXmlBytes));
    final shared = _sharedStrings(zip.readText('xl/sharedStrings.xml', zipLimits.maxXmlBytes), limits, budget);

    final sheets = <SheetData>[];
    var totalCells = 0;
    for (final s in _sheetList(workbook)) {
      if (sheets.length >= limits.maxSheets) break;
      final rel = rels[s.rid];
      if (rel == null || rel.external) continue;
      final part = resolvePartName('xl', rel.target);
      if (part == null) throw const ReaderOpenException(ReaderFailure.unsafe);
      if (!part.startsWith('xl/worksheets/')) continue; // chartsheets, dialogs
      final xml = zip.readText(part, zipLimits.maxXmlBytes);
      if (xml == null) continue;
      final sheet = _parseSheet(s.name, xml, shared, limits, limits.maxCells - totalCells, budget);
      totalCells += sheet.rows.fold<int>(0, (n, r) => n + r.length);
      sheets.add(sheet);
    }
    if (sheets.isEmpty) {
      sheets.add(const SheetData(name: 'Sheet1', rows: [], columnCount: 0));
    }
    return ReaderDocument(kind: DocumentKind.sheet, sheets: sheets, notice: xlsxNotice);
  } on ReaderOpenException {
    rethrow;
  } on ZipBomb {
    throw const ReaderOpenException(ReaderFailure.unsafe);
  } catch (_) {
    throw const ReaderOpenException(ReaderFailure.damaged);
  }
}

ReaderDocument parseXlsxFile(String path, {ParseBudget? budget}) {
  final f = io.File(path);
  if (f.lengthSync() > SecurityLimits.maxDocxFileBytes) throw const ReaderOpenException(ReaderFailure.tooLarge);
  return parseXlsx(f.readAsBytesSync(), budget: budget);
}

/// Resolves an OPC relationship [target] against [baseDir] ("xl"). Returns
/// null for anything that escapes the package (`..` above the root,
/// backslashes, schemes).
String? resolvePartName(String baseDir, String target) {
  if (target.isEmpty || target.contains('\\') || target.contains(':') || target.contains('\u0000')) return null;
  final parts = <String>[];
  final segs = target.startsWith('/') ? target.substring(1).split('/') : [...baseDir.split('/'), ...target.split('/')];
  for (final s in segs) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(s);
    }
  }
  return parts.isEmpty ? null : parts.join('/');
}

List<({String name, String rid})> _sheetList(String xml) {
  final out = <({String name, String rid})>[];
  for (final e in xmlEvents(xml)) {
    if (e is XmlStartElementEvent && xmlLocal(e.name) == 'sheet') {
      final state = xmlAttr(e, 'state');
      if (state == 'hidden' || state == 'veryHidden') continue;
      final rid = xmlAttr(e, 'id');
      if (rid == null) continue;
      out.add((name: _clip(xmlAttr(e, 'name') ?? 'Sheet${out.length + 1}', 100), rid: rid));
    }
  }
  return out;
}

String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;

/// Shared string table; phonetic runs (`rPh`) are skipped.
List<String> _sharedStrings(String? xml, SheetLimits limits, ParseBudget? budget) {
  final out = <String>[];
  if (xml == null) return out;
  StringBuffer? cur;
  var inT = false, phonetic = 0, n = 0;
  for (final e in xmlEvents(xml)) {
    if ((++n & 0x3FFF) == 0) budget?.check();
    if (e is XmlStartElementEvent) {
      switch (xmlLocal(e.name)) {
        case 'si':
          cur = StringBuffer();
          if (e.isSelfClosing) {
            out.add('');
            cur = null;
          }
        case 'rPh':
          if (!e.isSelfClosing) phonetic++;
        case 't':
          inT = !e.isSelfClosing;
      }
    } else if (e is XmlEndElementEvent) {
      switch (xmlLocal(e.name)) {
        case 'si':
          if (cur != null) out.add(_clip(cur.toString(), limits.maxCellChars));
          cur = null;
        case 'rPh':
          if (phonetic > 0) phonetic--;
        case 't':
          inT = false;
      }
    } else if (inT && phonetic == 0 && cur != null && cur.length <= limits.maxCellChars) {
      if (e is XmlTextEvent) cur.write(e.value);
      if (e is XmlCDATAEvent) cur.write(e.value);
    }
  }
  return out;
}

/// "BC12" → column index 54 (0-based), or null.
int? columnIndexOf(String ref) {
  var col = 0, i = 0;
  while (i < ref.length) {
    final c = ref.codeUnitAt(i) | 0x20; // lower-case
    if (c < 0x61 || c > 0x7A) break;
    col = col * 26 + (c - 0x60);
    if (col > 16384) return null;
    i++;
  }
  return i == 0 ? null : col - 1;
}

/// Shows a stored number the way a person expects: 3 not 3.0, 0.1 not
/// 0.10000000000000001, 12.5 not 12.500000000000002.
String formatXlsxNumber(String raw) {
  final d = double.tryParse(raw.trim());
  if (d == null || !d.isFinite) return raw;
  if (d == d.truncateToDouble() && d.abs() < 1e15) return d.toInt().toString();
  // Excel shows at most 15 significant digits: 12.500000000000002 → 12.5.
  final s = double.parse(d.toStringAsPrecision(15)).toString();
  return s.contains('e') ? d.toStringAsPrecision(10) : s;
}

SheetData _parseSheet(
  String name,
  String xml,
  List<String> shared,
  SheetLimits limits,
  int cellBudget,
  ParseBudget? budget,
) {
  final rows = <List<String>>[];
  var columns = 0, cells = 0, n = 0;
  var truncated = false;
  List<String>? row;
  var nextRow = 0;

  // Current cell.
  int? col;
  String? type;
  StringBuffer? value; // <v>
  StringBuffer? inline; // <is><t>
  var inV = false, inT = false, phonetic = 0;
  var nextCol = 0;

  void addRow(List<String> r) {
    // Trim trailing empty cells so sparse styling doesn't widen the grid.
    var len = r.length;
    while (len > 0 && r[len - 1].isEmpty) {
      len--;
    }
    final trimmed = len == r.length ? r : r.sublist(0, len);
    rows.add(trimmed);
    if (trimmed.length > columns) columns = trimmed.length;
  }

  for (final e in xmlEvents(xml)) {
    if ((++n & 0x3FFF) == 0) budget?.check();
    if (e is XmlStartElementEvent) {
      switch (xmlLocal(e.name)) {
        case 'row':
          final r = int.tryParse(xmlAttr(e, 'r') ?? '');
          final index = r != null && r >= 1 ? r - 1 : nextRow;
          if (index >= limits.maxRows) {
            truncated = true;
            break;
          }
          // Fill skipped rows so row numbers line up with Excel.
          while (rows.length < index) {
            rows.add(const []);
          }
          row = <String>[];
          nextCol = 0;
          nextRow = index + 1;
          if (e.isSelfClosing) {
            addRow(row);
            row = null;
          }
        case 'c':
          if (row == null) break;
          final ref = xmlAttr(e, 'r');
          col = ref == null ? nextCol : columnIndexOf(ref) ?? nextCol;
          type = xmlAttr(e, 't');
          value = null;
          inline = null;
          if (e.isSelfClosing) col = null;
        case 'v':
          if (col != null && !e.isSelfClosing) {
            inV = true;
            value = StringBuffer();
          }
        case 'is':
          if (col != null) inline = StringBuffer();
        case 'rPh':
          if (!e.isSelfClosing) phonetic++;
        case 't':
          if (inline != null) inT = !e.isSelfClosing;
      }
    } else if (e is XmlEndElementEvent) {
      switch (xmlLocal(e.name)) {
        case 'v':
          inV = false;
        case 't':
          inT = false;
        case 'rPh':
          if (phonetic > 0) phonetic--;
        case 'c':
          final c = col, r = row;
          col = null;
          if (c == null || r == null) break;
          nextCol = c + 1;
          if (c >= limits.maxColumns) {
            truncated = true;
            break;
          }
          if (cells >= cellBudget) {
            truncated = true;
            break;
          }
          final text = _cellText(type, value?.toString(), inline?.toString(), shared);
          if (text.isEmpty) break;
          while (r.length < c) {
            r.add('');
          }
          if (r.length == c) {
            r.add(_clip(text, limits.maxCellChars));
          } else {
            r[c] = _clip(text, limits.maxCellChars);
          }
          cells++;
        case 'row':
          if (row case final r?) addRow(r);
          row = null;
          if (cells >= cellBudget) truncated = true;
      }
      if (truncated && (rows.length >= limits.maxRows || cells >= cellBudget)) break;
    } else if (e is XmlTextEvent || e is XmlCDATAEvent) {
      final t = e is XmlTextEvent ? e.value : (e as XmlCDATAEvent).value;
      if (inV && value != null && value.length <= limits.maxCellChars) value.write(t);
      if (inT && phonetic == 0 && inline != null && inline.length <= limits.maxCellChars) inline.write(t);
    }
  }
  // Drop trailing empty rows.
  var end = rows.length;
  while (end > 0 && rows[end - 1].isEmpty) {
    end--;
  }
  return SheetData(
    name: name,
    rows: end == rows.length ? rows : rows.sublist(0, end),
    columnCount: columns,
    truncated: truncated,
  );
}

String _cellText(String? type, String? v, String? inline, List<String> shared) {
  switch (type) {
    case 's':
      final i = int.tryParse(v?.trim() ?? '');
      return i != null && i >= 0 && i < shared.length ? shared[i] : '';
    case 'inlineStr':
      return inline ?? v ?? '';
    case 'b':
      final t = v?.trim();
      return t == '1' ? 'TRUE' : (t == '0' ? 'FALSE' : (t ?? ''));
    case 'str':
    case 'e':
    case 'd':
      return v ?? '';
    default:
      if (v == null) return inline ?? '';
      return formatXlsxNumber(v);
  }
}
