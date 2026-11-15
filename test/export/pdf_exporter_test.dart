import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/models/export_job.dart';
import 'package:pdfreader/core/pdf/page_editor.dart';
import 'package:pdfreader/features/export/export_support.dart';
import 'package:pdfreader/features/export/pdf_exporter.dart';
import 'package:pdfrx/pdfrx.dart';

import 'test_pdfs.dart';

/// Records calls; returns a real PDF with as many pages as requested.
class FakePageEditor implements PageEditor {
  final calls = <String>[];
  List<Annotation>? flattened;
  List<int>? rebuiltPages;
  int? rebuildSourcePageCount;

  @override
  Future<List<int>> flatten(PdfDocument source, List<Annotation> annotations) async {
    calls.add('flatten');
    flattened = annotations;
    return buildSamplePdf(pages: source.pages.length);
  }

  @override
  Future<List<int>> rebuild(PdfDocument source, List<PageSpec> pages) async {
    calls.add('rebuild');
    rebuiltPages = [for (final s in pages) s.pageNumber];
    rebuildSourcePageCount = source.pages.length;
    return buildSamplePdf(pages: pages.length);
  }

  @override
  Future<List<int>> merge(List<PdfDocument> docs) => throw UnimplementedError();
  @override
  Future<List<List<int>>> split(PdfDocument source, List<List<int>> ranges) => throw UnimplementedError();
}

void main() {
  setUpAll(initEngine);

  late PdfDocument doc;
  setUp(() async => doc = await openBytes(await buildSamplePdf(pages: 4)));
  tearDown(() => doc.dispose());

  test('no annotations: rebuild with all pages', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final ed = FakePageEditor();
    final r = await PdfExporter(temp, () => ed)
        .export(doc, const ExportOptions(format: ExportFormat.pdf), baseName: 'Out');
    expect(ed.calls, ['rebuild']);
    expect(ed.rebuiltPages, [1, 2, 3, 4]);
    expect(p.basename(r.files.single), 'Out.pdf');
    expect(String.fromCharCodes(File(r.files.single).readAsBytesSync().take(5)), '%PDF-');
  });

  test('annotations + all pages: flatten only', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final ed = FakePageEditor();
    await PdfExporter(temp, () => ed).export(doc, const ExportOptions(format: ExportFormat.pdf),
        baseName: 'x', annotations: [fakeAnnotation(page: 1), fakeAnnotation(page: 3)]);
    expect(ed.calls, ['flatten']);
    expect(ed.flattened, hasLength(2));
  });

  test('annotations + subset: flatten then rebuild the flattened copy', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final ed = FakePageEditor();
    await PdfExporter(temp, () => ed).export(doc, const ExportOptions(format: ExportFormat.pdf, pages: [2, 3]),
        baseName: 'x', annotations: [fakeAnnotation(page: 1), fakeAnnotation(page: 3)]);
    expect(ed.calls, ['flatten', 'rebuild']);
    expect(ed.flattened!.map((a) => a.page), [3]); // only annotations on exported pages
    expect(ed.rebuiltPages, [2, 3]);
    expect(ed.rebuildSourcePageCount, 4);
  });

  test('includeAnnotations=false ignores annotations', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final ed = FakePageEditor();
    await PdfExporter(temp, () => ed).export(
        doc, const ExportOptions(format: ExportFormat.pdf, pages: [4], includeAnnotations: false),
        baseName: 'x', annotations: [fakeAnnotation()]);
    expect(ed.calls, ['rebuild']);
    expect(ed.rebuiltPages, [4]);
  });

  test('missing editor implementation becomes a user-facing failure', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    await expectLater(
      PdfExporter(temp, () => throw UnimplementedError())
          .export(doc, const ExportOptions(format: ExportFormat.pdf), baseName: 'x'),
      throwsA(isA<ExportFailure>()),
    );
    expect(temp.dir.listSync(recursive: true), isEmpty);
  });

  test('cancellation', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    await expectLater(
      PdfExporter(temp, FakePageEditor.new)
          .export(doc, const ExportOptions(format: ExportFormat.pdf), baseName: 'x', isCancelled: () => true),
      throwsA(isA<ExportCancelledException>()),
    );
    expect(temp.dir.listSync(recursive: true), isEmpty);
  });
}
