import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/models/export_job.dart';
import 'package:pdfreader/core/security/limits.dart';
import 'package:pdfreader/features/export/export_support.dart';
import 'package:pdfreader/features/export/image_exporter.dart';

import 'test_pdfs.dart';

void main() {
  setUpAll(initEngine);

  group('RenderSize', () {
    test('scales with DPI', () {
      final s = RenderSize.compute(612, 792, 144);
      expect((s.width, s.height), (1224, 1584));
      expect(s.scaledDown, isFalse);
    });
    test('caps total pixels, keeps aspect', () {
      final s = RenderSize.compute(14400, 14400, 600);
      expect(s.width * s.height, lessThanOrEqualTo(SecurityLimits.maxRenderPixels));
      expect(s.scaledDown, isTrue);
      expect((s.width - s.height).abs(), lessThanOrEqualTo(1));
    });
    test('caps a single side for extreme aspect ratios', () {
      final s = RenderSize.compute(14400, 3, 1200);
      expect(s.width, lessThanOrEqualTo(RenderSize.maxSide));
      expect(s.height, greaterThanOrEqualTo(1));
    });
    test('handles invalid sizes and clamps DPI', () {
      final s = RenderSize.compute(double.nan, -5, 1);
      expect(s.width, greaterThan(0));
      expect(RenderSize.compute(72, 72, 100000).width, 72 * RenderSize.maxDpi ~/ 72);
    });
  });

  test('sanitizeBaseName / pageFileName', () {
    expect(sanitizeBaseName('../a/b:c*'), '_a_b_c_');
    expect(sanitizeBaseName('...'), 'document');
    expect(sanitizeBaseName('  '), 'document');
    expect(sanitizeBaseName('रिपोर्ट'), 'रिपोर्ट');
    expect(pageFileName('doc', 7, 'png'), 'doc_p007.png');
    expect(pageFileName('doc', 1234, 'jpg'), 'doc_p1234.jpg');
  });

  test('PNG export: one file per page, dimensions follow DPI', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSizedPdf(200, 100));
    addTearDown(doc.dispose);
    final progress = <(int, int)>[];
    final r = await ImageExporter(temp).export(
      doc,
      const ExportOptions(format: ExportFormat.png, dpi: 144),
      baseName: 'my doc',
      onProgress: (d, t) => progress.add((d, t)),
    );
    expect(r.files, hasLength(1));
    expect(p.basename(r.files.single), 'my doc_p001.png');
    final decoded = img.decodePng(File(r.files.single).readAsBytesSync())!;
    expect((decoded.width, decoded.height), (400, 200));
    // White background, opaque.
    final px = decoded.getPixel(decoded.width - 2, decoded.height - 2);
    expect((px.r, px.g, px.b), (255, 255, 255));
    expect(progress.last, (1, 1));
  });

  test('JPG export of selected pages honours quality and naming', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSamplePdf(pages: 3));
    addTearDown(doc.dispose);
    final r = await ImageExporter(temp).export(
      doc,
      const ExportOptions(format: ExportFormat.jpg, dpi: 72, pages: [3, 1], jpgQuality: 60),
      baseName: 'Sample',
    );
    expect(r.files.map(p.basename), ['Sample_p003.jpg', 'Sample_p001.jpg']);
    final decoded = img.decodeJpg(File(r.files.first).readAsBytesSync())!;
    expect(decoded.width, closeTo(595, 1)); // A4 at 72 dpi
    expect(decoded.height, closeTo(842, 1));
  });

  test('pixel cap scales huge pages down', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSizedPdf(5000, 5000));
    addTearDown(doc.dispose);
    final r = await ImageExporter(temp).export(
      doc,
      const ExportOptions(format: ExportFormat.jpg, dpi: 300), // 20833² requested
      baseName: 'big',
    );
    final decoded = img.decodeJpg(File(r.files.single).readAsBytesSync())!;
    expect(decoded.width * decoded.height, lessThanOrEqualTo(SecurityLimits.maxRenderPixels));
    expect(decoded.width, greaterThan(3000));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('cancellation stops the export and removes partial output', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final doc = await openBytes(await buildSamplePdf(pages: 3));
    addTearDown(doc.dispose);
    var cancel = false;
    await expectLater(
      ImageExporter(temp).export(
        doc,
        const ExportOptions(format: ExportFormat.png, dpi: 72),
        baseName: 'c',
        onProgress: (d, _) => cancel = d >= 1,
        isCancelled: () => cancel,
      ),
      throwsA(isA<ExportCancelledException>()),
    );
    expect(temp.dir.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('annotations are flattened through the injected flattener', () async {
    final temp = newTemp();
    addTearDown(() => temp.dir.deleteSync(recursive: true));
    final bytes = await buildSamplePdf(pages: 1);
    final doc = await openBytes(bytes);
    addTearDown(doc.dispose);
    var calls = 0;
    final exporter = ImageExporter(temp, flatten: (d, a) async {
      calls++;
      return buildSizedPdf(100, 50);
    });
    final r = await exporter.export(
      doc,
      const ExportOptions(format: ExportFormat.png, dpi: 72),
      baseName: 'a',
      annotations: [fakeAnnotation()],
    );
    expect(calls, 1);
    final decoded = img.decodePng(File(r.files.single).readAsBytesSync())!;
    expect((decoded.width, decoded.height), (100, 50)); // rendered from the flattened copy
  });
}
