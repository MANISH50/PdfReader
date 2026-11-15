import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfreader/core/models/export_job.dart';
import 'package:pdfreader/features/export/docx/docx_writer.dart';
import 'package:pdfreader/features/export/docx/layout.dart';
import 'package:pdfreader/features/export/docx_exporter.dart';
import 'package:pdfreader/features/export/export_support.dart';
import 'package:xml/xml.dart';

import 'test_pdfs.dart';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/// Unzips a DOCX, checks the package structure and parses every XML part.
Map<String, XmlDocument> validateDocx(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final names = archive.files.map((f) => f.name).toSet();
  expect(archive.files.first.name, '[Content_Types].xml');
  for (final required in [
    '[Content_Types].xml',
    '_rels/.rels',
    'word/document.xml',
    'word/styles.xml',
    'word/_rels/document.xml.rels',
    'docProps/core.xml',
    'docProps/app.xml',
  ]) {
    expect(names, contains(required));
  }
  final xml = <String, XmlDocument>{};
  for (final f in archive.files) {
    if (f.name.endsWith('.xml') || f.name.endsWith('.rels')) {
      xml[f.name] = XmlDocument.parse(utf8.decode(f.content)); // throws if malformed
    }
  }
  // Every relationship target exists, every override part exists.
  for (final relsName in ['_rels/.rels', 'word/_rels/document.xml.rels']) {
    final base = relsName.startsWith('word/') ? 'word/' : '';
    for (final rel in xml[relsName]!.findAllElements('Relationship')) {
      expect(names, contains('$base${rel.getAttribute('Target')}'), reason: rel.toXmlString());
    }
  }
  for (final o in xml['[Content_Types].xml']!.findAllElements('Override')) {
    expect(names, contains(o.getAttribute('PartName')!.substring(1)));
  }
  // Every embedded image is referenced by a relationship id that exists.
  final relIds = xml['word/_rels/document.xml.rels']!
      .findAllElements('Relationship')
      .map((r) => r.getAttribute('Id'))
      .toSet();
  final doc = xml['word/document.xml']!;
  for (final blip in doc.descendants.whereType<XmlElement>().where((e) => e.localName == 'blip')) {
    expect(relIds, contains(blip.getAttribute('r:embed')));
  }
  expect(doc.rootElement.name.local, 'document');
  expect(doc.rootElement.namespaceUri, _w);
  return xml;
}

List<XmlElement> paragraphs(XmlDocument doc) =>
    doc.findAllElements('w:p').toList();

String paraText(XmlElement p) => p.findAllElements('w:t').map((t) => t.innerText).join();

String? paraStyle(XmlElement p) => p.findAllElements('w:pStyle').firstOrNull?.getAttribute('w:val');

void main() {
  setUpAll(initEngine);

  group('DocxWriter', () {
    TextParagraph para(String text, {bool rtl = false, BlockKind kind = BlockKind.paragraph, bool bold = false}) =>
        TextParagraph(runs: [TextRun(text, bold: bold)], fontSize: 11, rtl: rtl, lineCount: 1)..kind = kind;

    test('produces a valid package with headings, RTL, escaping and page breaks', () {
      final pages = [
        DocxPage(widthPt: 595, heightPt: 842, paragraphs: [
          para('Title', kind: BlockKind.heading1),
          para('A & B < C > "D"\tTabbed\u0001 ctrl', bold: true),
        ]),
        DocxPage(widthPt: 595, heightPt: 842, paragraphs: [para('שלום עולם', rtl: true), para('नमस्ते')]),
      ];
      final parts = DocxWriter(title: 'T & T', created: DateTime.utc(2026)).buildParts(pages, 11);
      final xml = validateDocx(DocxWriter.zip(parts));
      final doc = xml['word/document.xml']!;
      final ps = paragraphs(doc);
      expect(paraStyle(ps[0]), 'Heading1');
      expect(paraText(ps[1]), 'A & B < C > "D"Tabbed ctrl');
      expect(ps[1].findAllElements('w:tab'), hasLength(1));
      expect(ps[1].findAllElements('w:b'), isNotEmpty);
      final br = ps[2].findAllElements('w:br').single;
      expect(br.getAttribute('w:type'), 'page');
      expect(ps[3].findAllElements('w:bidi'), hasLength(1));
      expect(ps[3].findAllElements('w:rtl'), isNotEmpty);
      expect(paraText(ps[3]), 'שלום עולם');
      expect(paraText(ps[4]), 'नमस्ते');
      expect(xml['docProps/core.xml']!.findAllElements('dc:title').single.innerText, 'T & T');
      final styles = xml['word/styles.xml']!;
      final ids = styles.findAllElements('w:style').map((s) => s.getAttribute('w:styleId')).toSet();
      expect(ids, containsAll(['Normal', 'Heading1', 'Heading2', 'Heading3']));
      final pgSz = doc.findAllElements('w:pgSz').single;
      expect(pgSz.getAttribute('w:w'), '11900');
    });

    test('embeds images with content type and relationship', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      final parts = DocxWriter(title: 'x').buildParts([
        DocxPage(
          widthPt: 842,
          heightPt: 595,
          paragraphs: const [],
          image: DocxImage(jpeg, pixelWidth: 200, pixelHeight: 100),
        ),
      ], 0);
      final xml = validateDocx(DocxWriter.zip(parts));
      expect(parts.keys, contains('word/media/image1.jpeg'));
      final defaults = xml['[Content_Types].xml']!.findAllElements('Default').map((d) => d.getAttribute('Extension'));
      expect(defaults, contains('jpeg'));
      expect(xml['word/document.xml']!.findAllElements('w:pgSz').single.getAttribute('w:orient'), 'landscape');
    });

    test('empty document is still valid', () {
      validateDocx(DocxWriter.zip(DocxWriter(title: '').buildParts(const [], 0)));
    });

    test('xmlEscape drops invalid XML characters and lone surrogates', () {
      expect(xmlEscape('a\u0000b￾c\uD800d😀'), 'abcd😀');
      expect(xmlEscape('<&>"'), '&lt;&amp;&gt;&quot;');
    });
  });

  group('DocxExporter (engine)', () {
    test('headings, paragraphs, bold/italic, page breaks and scanned-page image', () async {
      final temp = newTemp();
      addTearDown(() => temp.dir.deleteSync(recursive: true));
      final doc = await openBytes(await buildSamplePdf(pages: 3));
      addTearDown(doc.dispose);
      final progress = <int>[];
      final r = await DocxExporter(temp).export(doc, const ExportOptions(format: ExportFormat.docx),
          baseName: 'Report', onProgress: (d, _) => progress.add(d));
      expect(r.files.single, endsWith('Report.docx'));
      expect(progress.last, 3);
      final xml = validateDocx(File(r.files.single).readAsBytesSync());
      final ps = paragraphs(xml['word/document.xml']!);
      final texts = ps.map(paraText).toList();

      final title = ps.firstWhere((p) => paraText(p) == 'Chapter 1 Title');
      expect(paraStyle(title), 'Heading1');
      final section = ps.firstWhere((p) => paraText(p) == 'Section 1.1');
      expect(paraStyle(section), anyOf('Heading2', 'Heading3'));

      // The wrapped body paragraph is one paragraph, joined with spaces.
      final body = texts.firstWhere((t) => t.startsWith('The quick brown fox'));
      expect(body, endsWith('First.'));
      expect(body, contains('sensible line joining and wrapping'));

      final emph = ps.firstWhere((p) => paraText(p).startsWith('Emphasised'));
      expect(emph.findAllElements('w:i'), isNotEmpty, reason: 'italic detected via PDFium font flags');

      // Two page breaks between three pages.
      final breaks = xml['word/document.xml']!
          .findAllElements('w:br')
          .where((b) => b.getAttribute('w:type') == 'page');
      expect(breaks, hasLength(2));

      // Page 3 has no text: it is embedded as an image so content is not lost.
      final archive = ZipDecoder().decodeBytes(File(r.files.single).readAsBytesSync());
      final media = archive.files.where((f) => f.name.startsWith('word/media/')).toList();
      expect(media, hasLength(1));
      expect(media.single.content.sublist(0, 2), [0xFF, 0xD8]);
    });

    test('works without the PDFium style probe (fallback)', () async {
      final temp = newTemp();
      addTearDown(() => temp.dir.deleteSync(recursive: true));
      final doc = await openBytes(await buildSamplePdf(pages: 1));
      addTearDown(doc.dispose);
      final r = await DocxExporter(temp, probeStyles: null, embedImagesForScans: false)
          .export(doc, const ExportOptions(format: ExportFormat.docx), baseName: 'x');
      final ps = paragraphs(validateDocx(File(r.files.single).readAsBytesSync())['word/document.xml']!);
      expect(paraStyle(ps.firstWhere((p) => paraText(p) == 'Chapter 1 Title')), 'Heading1');
    });

    test('Hebrew / Arabic text becomes RTL paragraphs', () async {
      const fontPath = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';
      final font = pw.Font.ttf(File(fontPath).readAsBytesSync().buffer.asByteData());
      final pdf = pw.Document();
      pdf.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (c) => pw.Column(children: [
          pw.Text('שלום עולם', style: pw.TextStyle(font: font, fontSize: 14), textDirection: pw.TextDirection.rtl),
          pw.SizedBox(height: 30),
          pw.Text('Hello world in English', style: pw.TextStyle(font: font, fontSize: 14)),
        ]),
      ));
      final temp = newTemp();
      addTearDown(() => temp.dir.deleteSync(recursive: true));
      final doc = await openBytes(await pdf.save());
      addTearDown(doc.dispose);
      final r = await DocxExporter(temp, embedImagesForScans: false)
          .export(doc, const ExportOptions(format: ExportFormat.docx), baseName: 'rtl');
      final ps = paragraphs(validateDocx(File(r.files.single).readAsBytesSync())['word/document.xml']!);
      final hebrew = ps.firstWhere((p) => RegExp('[֐-׿]').hasMatch(paraText(p)));
      expect(hebrew.findAllElements('w:bidi'), hasLength(1));
      final english = ps.firstWhere((p) => paraText(p).contains('Hello'));
      expect(english.findAllElements('w:bidi'), isEmpty);
    }, skip: File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf').existsSync() ? false : 'DejaVuSans not installed');

    test('cancellation cleans up', () async {
      final temp = newTemp();
      addTearDown(() => temp.dir.deleteSync(recursive: true));
      final doc = await openBytes(await buildSamplePdf(pages: 3));
      addTearDown(doc.dispose);
      var done = 0;
      await expectLater(
        DocxExporter(temp).export(doc, const ExportOptions(format: ExportFormat.docx),
            baseName: 'x', onProgress: (d, _) => done = d, isCancelled: () => done >= 1),
        throwsA(isA<ExportCancelledException>()),
      );
      expect(temp.dir.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  });
}
