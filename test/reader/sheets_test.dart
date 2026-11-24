import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/documents/document_kind.dart';
import 'package:pdfreader/features/reader/csv_parser.dart';
import 'package:pdfreader/features/reader/docx_parser.dart' show DocxLimits;
import 'package:pdfreader/features/reader/reader_model.dart';
import 'package:pdfreader/features/reader/xlsx_parser.dart';

import 'fixtures.dart';

const _workbook = '''<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="Budget" sheetId="1" r:id="rId1"/>
<sheet name="Secret" sheetId="3" state="hidden" r:id="rId3"/>
<sheet name="Notes" sheetId="2" r:id="rId2"/>
</sheets></workbook>''';

const _rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="worksheet" Target="/xl/worksheets/sheet2.xml"/>
<Relationship Id="rId3" Type="worksheet" Target="worksheets/sheet3.xml"/>
</Relationships>''';

const _shared = '''<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<si><t>Item</t></si>
<si><t>Cost</t></si>
<si><r><t>Rich </t></r><r><t>text</t></r><rPh><t>PHONETIC</t></rPh></si>
</sst>''';

const _sheet1 = '''<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>12.5</v></c></row>
<row r="4"><c r="A4" t="inlineStr"><is><t>Total</t></is></c><c r="B4"><f>SUM(B2:B3)</f><v>12.500000000000002</v></c><c r="D4" t="b"><v>1</v></c></row>
<row r="5"><c r="C5" t="e"><v>#DIV/0!</v></c><c r="E5" s="3"/></row>
</sheetData></worksheet>''';

const _sheet2 = '''<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
<row r="1"><c r="A1" t="str"><v>hello</v></c><c r="B1"><v>3</v></c></row>
</sheetData></worksheet>''';

Uint8List sampleXlsx({String sheet1 = _sheet1, String rels = _rels, Map<String, List<int>> extra = const {}}) =>
    buildZip({
      'xl/workbook.xml': utf8.encode(_workbook),
      'xl/_rels/workbook.xml.rels': utf8.encode(rels),
      'xl/sharedStrings.xml': utf8.encode(_shared),
      'xl/worksheets/sheet1.xml': utf8.encode(sheet1),
      'xl/worksheets/sheet2.xml': utf8.encode(_sheet2),
      'xl/worksheets/sheet3.xml': utf8.encode(_sheet2),
      ...extra,
    });

Matcher fails(ReaderFailure f) => throwsA(isA<ReaderOpenException>().having((e) => e.failure, 'failure', f));

void main() {
  group('CSV / TSV', () {
    SheetData parse(String text, {String? ext, SheetLimits limits = const SheetLimits()}) =>
        parseDelimited(text, extension: ext, limits: limits).sheets!.single;

    test('quotes, escaped quotes, newlines in quotes, CRLF, BOM', () {
      final s = parse('﻿name,note\r\n"Smith, J","said ""hi""\nthen left"\r\nA,\n');
      expect(s.rows, [
        ['name', 'note'],
        ['Smith, J', 'said "hi"\nthen left'],
        ['A', ''],
      ]);
      expect(s.columnCount, 2);
    });

    test('delimiter sniffing: semicolon, tab, and .tsv', () {
      expect(parse('a;b;c\n1;2,5;3\n').rows[1], ['1', '2,5', '3']);
      expect(parse('a\tb\n1\t2\n').rows[0], ['a', 'b']);
      expect(parse('a,b\tc\n', ext: '.tsv').rows[0], ['a,b', 'c']);
      expect(sniffDelimiter('one column\nonly\n'), ',');
    });

    test('ragged rows keep the widest column count', () {
      final s = parse('a\nb,c,d\ne,f\n');
      expect(s.columnCount, 3);
      expect(s.cell(0, 2), '');
      expect(s.cell(1, 2), 'd');
    });

    test('row, column and cell-length caps truncate instead of failing', () {
      final big = List.generate(50, (i) => '$i,x').join('\n');
      final s = parse(big, limits: const SheetLimits(maxRows: 10));
      expect(s.rows.length, 10);
      expect(s.truncated, isTrue);
      final wide = parse(List.filled(20, 'v').join(','), limits: const SheetLimits(maxColumns: 5));
      expect(wide.columnCount, 5);
      expect(wide.truncated, isTrue);
      final long = parse('"${'z' * 100}"', limits: const SheetLimits(maxCellChars: 10));
      expect(long.cell(0, 0), 'z' * 10);
      expect(long.truncated, isTrue);
    });

    test('unterminated quote reads to the end without hanging', () {
      expect(parse('a,"open\nstill open').rows.single, ['a', 'open\nstill open']);
    });
  });

  group('XLSX', () {
    test('reads visible sheets, shared/inline strings, numbers, booleans, errors, gaps', () {
      final doc = parseXlsx(sampleXlsx());
      expect(doc.kind, DocumentKind.sheet);
      expect(doc.notice, xlsxNotice);
      final sheets = doc.sheets!;
      expect(sheets.map((s) => s.name), ['Budget', 'Notes']); // hidden sheet skipped
      final b = sheets.first;
      expect(b.rows[0], ['Item', 'Cost']);
      expect(b.rows[1], ['Rich text', '12.5']); // phonetic run skipped
      expect(b.rows[2], isEmpty); // missing row 3 kept so numbers line up
      expect(b.rows[3], ['Total', '12.5', '', 'TRUE']);
      expect(b.rows[4], ['', '', '#DIV/0!']); // empty styled E5 trimmed
      expect(b.columnCount, 4);
      expect(sheets[1].rows.single, ['hello', '3']);
    });

    test('number formatting', () {
      expect(formatXlsxNumber('3'), '3');
      expect(formatXlsxNumber('3.0'), '3');
      expect(formatXlsxNumber('0.10000000000000001'), '0.1');
      expect(formatXlsxNumber('-42.25'), '-42.25');
      expect(formatXlsxNumber('12.500000000000002'), '12.5');
      expect(formatXlsxNumber('1234567.891'), '1234567.891');
      expect(formatXlsxNumber('abc'), 'abc');
    });

    test('column references', () {
      expect(columnIndexOf('A1'), 0);
      expect(columnIndexOf('Z9'), 25);
      expect(columnIndexOf('AA10'), 26);
      expect(columnIndexOf('XFD1'), 16383);
      expect(columnIndexOf('12'), isNull);
      expect(columnLabel(0), 'A');
      expect(columnLabel(27), 'AB');
    });

    test('part names that escape the package are refused', () {
      expect(resolvePartName('xl', 'worksheets/sheet1.xml'), 'xl/worksheets/sheet1.xml');
      expect(resolvePartName('xl', '/xl/worksheets/s.xml'), 'xl/worksheets/s.xml');
      expect(resolvePartName('xl', '../../etc/passwd'), isNull);
      expect(resolvePartName('xl', 'file:///etc/passwd'), isNull);
      final evil = _rels.replaceFirst('worksheets/sheet1.xml', '../../../evil.xml');
      expect(() => parseXlsx(sampleXlsx(rels: evil)), fails(ReaderFailure.unsafe));
    });

    test('DOCTYPE entities are never expanded', () {
      const xxe = '''<?xml version="1.0"?>
<!DOCTYPE x [<!ENTITY boom "BOOMBOOMBOOM"><!ENTITY file SYSTEM "file:///etc/passwd">]>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
<row r="1"><c r="A1" t="inlineStr"><is><t>a&boom;&file;b</t></is></c></row></sheetData></worksheet>''';
      final all = parseXlsx(sampleXlsx(sheet1: xxe)).sheets!.first.rows.expand((r) => r).join();
      expect(all, isNot(contains('BOOMBOOMBOOM')));
      expect(all, isNot(contains('root:')));
    });

    test('zip bombs and oversized parts are refused', () {
      final huge = _sheet1.replaceFirst('<sheetData>', '<sheetData>${' ' * 300000}');
      expect(
        () => parseXlsx(sampleXlsx(sheet1: huge), zipLimits: const DocxLimits(maxXmlBytes: 100000)),
        fails(ReaderFailure.unsafe),
      );
      final lying = lieAboutSize(sampleXlsx(sheet1: huge), 'xl/worksheets/sheet1.xml', 1000);
      expect(() => parseXlsx(lying, zipLimits: const DocxLimits(maxXmlBytes: 100000)), fails(ReaderFailure.unsafe));
    });

    test('row and cell caps truncate', () {
      final rows = List.generate(30, (i) => '<row r="${i + 1}"><c r="A${i + 1}"><v>$i</v></c></row>').join();
      final xml = '<worksheet><sheetData>$rows</sheetData></worksheet>';
      final s = parseXlsx(sampleXlsx(sheet1: xml), limits: const SheetLimits(maxRows: 10)).sheets!.first;
      expect(s.rows.length, 10);
      expect(s.truncated, isTrue);
      final far = '<worksheet><sheetData><row r="5000000"><c r="A5000000"><v>1</v></c></row></sheetData></worksheet>';
      final f = parseXlsx(sampleXlsx(sheet1: far)).sheets!.first;
      expect(f.rows, isEmpty);
      expect(f.truncated, isTrue);
    });

    test('garbage is reported as damaged, not a crash', () {
      expect(() => parseXlsx(Uint8List.fromList(utf8.encode('not a zip'))), fails(ReaderFailure.damaged));
      expect(() => parseXlsx(buildZip({'x.xml': utf8.encode('<x/>')})), fails(ReaderFailure.damaged));
    });
  });

  group('sniffing', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('sheets_'));
    tearDown(() => tmp.deleteSync(recursive: true));
    String write(String name, List<int> bytes) => (File(p.join(tmp.path, name))..writeAsBytesSync(bytes)).path;

    test('csv, tsv and xlsx are sheets; macros and old .xls are not', () async {
      expect(await sniffDocumentKind(write('a.csv', utf8.encode('a,b\n1,2\n'))), DocumentKind.sheet);
      expect(await sniffDocumentKind(write('a.tsv', utf8.encode('a\tb\n'))), DocumentKind.sheet);
      expect(await sniffDocumentKind(write('x', utf8.encode('a,b')), displayName: 'Data.CSV'), DocumentKind.sheet);
      expect(await sniffDocumentKind(write('book.xlsx', sampleXlsx())), DocumentKind.sheet);
      expect(await sniffDocumentKind(write('noext', sampleXlsx())), DocumentKind.sheet);
      expect(await sniffDocumentKind(write('macro.xlsm', sampleXlsx())), isNull);
      // Legacy binary .xls (OLE2 header) is not supported.
      final ole = Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, ...List.filled(600, 0)]);
      expect(await sniffDocumentKind(write('old.xls', ole)), isNull);
    });
  });
}
