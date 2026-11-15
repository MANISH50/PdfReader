import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/models/export_job.dart';
import 'package:pdfreader/core/security/limits.dart';
import 'package:pdfreader/features/export/export_support.dart';
import 'package:pdfreader/features/export/text_exporter.dart';

import 'test_pdfs.dart';

void main() {
  setUpAll(initEngine);

  test('multi-page TXT with separators and reading order', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSamplePdf(pages: 3));
    addTearDown(doc.dispose);
    final r = await TextExporter(temp).export(doc, const ExportOptions(format: ExportFormat.txt), baseName: 'Notes');
    expect(p.basename(r.files.single), 'Notes.txt');
    final text = File(r.files.single).readAsStringSync();
    final pages = text.split('\f');
    expect(pages, hasLength(3));
    expect(pages[0], startsWith('--- Page 1 ---\nChapter 1 Title'));
    expect(pages[1], startsWith('--- Page 2 ---\nChapter 2 Title'));
    expect(pages[2].trim(), '--- Page 3 ---'); // blank page
    // Reading order: heading, body, section, body, emphasis.
    final p1 = pages[0];
    final order = ['Chapter 1 Title', 'First.', 'Section 1.1', 'Second.', 'Emphasised sentence on page 1.'];
    var last = -1;
    for (final s in order) {
      final i = p1.indexOf(s);
      expect(i, greaterThan(last), reason: s);
      last = i;
    }
  });

  test('page subset', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSamplePdf(pages: 3));
    addTearDown(doc.dispose);
    final r = await TextExporter(temp)
        .export(doc, const ExportOptions(format: ExportFormat.txt, pages: [2]), baseName: 'x');
    final text = File(r.files.single).readAsStringSync();
    expect(text, startsWith('--- Page 2 ---'));
    expect(text, isNot(contains('Page 1')));
    expect(text, isNot(contains('\f')));
  });

  test('RTL / Hindi text kept as Unicode, controls stripped, length capped', () {
    const mixed = 'שלום עולם\r\nمرحبا\nनमस्ते दुनिया  \u0007';
    expect(TextExporter.cleanText(mixed), 'שלום עולם\nمرحبا\nनमस्ते दुनिया');
    final huge = 'a' * (SecurityLimits.maxCharsPerPage + 50);
    expect(TextExporter.cleanText(huge).length, SecurityLimits.maxCharsPerPage);
    expect(TextExporter.formatPage(4, null, first: false), '\f--- Page 4 ---\n${TextExporter.unreadablePage}\n\n');
  });

  test('a failing page does not fail the export', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSamplePdf(pages: 2));
    addTearDown(doc.dispose);
    final r = await TextExporter(temp, loadText: (page) async {
      if (page.pageNumber == 1) throw StateError('boom');
      return 'ok';
    }).export(doc, const ExportOptions(format: ExportFormat.txt), baseName: 'x');
    final text = File(r.files.single).readAsStringSync();
    expect(text, contains(TextExporter.unreadablePage));
    expect(text, contains('ok'));
  });

  test('cancellation removes the partial file', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSamplePdf(pages: 3));
    addTearDown(doc.dispose);
    var done = 0;
    await expectLater(
      TextExporter(temp).export(doc, const ExportOptions(format: ExportFormat.txt),
          baseName: 'x', onProgress: (d, _) => done = d, isCancelled: () => done >= 2),
      throwsA(isA<ExportCancelledException>()),
    );
    expect(temp.dir.listSync(recursive: true).whereType<File>(), isEmpty);
  });
}
