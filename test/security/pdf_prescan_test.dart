import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/security/pdf_prescan.dart';

/// Minimal one-page PDF whose object 4 is [streamObj] (dictionary + stream).
Uint8List pdfWith(List<int> streamObj) {
  final b = BytesBuilder()
    ..add(ascii.encode('%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
        '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n'
        '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >> endobj\n4 0 obj '))
    ..add(streamObj)
    ..add(ascii.encode('\nendobj\ntrailer << /Root 1 0 R >>\n%%EOF\n'));
  return b.toBytes();
}

List<int> streamObj(String dictEntries, List<int> data, {bool lengthRef = false}) => [
      ...ascii.encode('<< /Length ${lengthRef ? '9 0 R' : data.length} $dictEntries >>\nstream\n'),
      ...data,
      ...ascii.encode('\nendstream'),
    ];

/// zlib(zlib(n zero bytes)) built in chunks, so the test never holds n bytes.
List<int> doubleFlate(int n) {
  final inner = <int>[];
  final enc = ZLibEncoder(level: 9).startChunkedConversion(ByteConversionSink.withCallback(inner.addAll));
  final chunk = Uint8List(4 << 20);
  for (var left = n; left > 0; left -= chunk.length) {
    enc.add(left >= chunk.length ? chunk : Uint8List.sublistView(chunk, 0, left));
  }
  enc.close();
  return ZLibEncoder(level: 9).convert(inner);
}

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('prescan'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<PdfPrescanResult> scanBytes(String name, Uint8List bytes, {PrescanLimits? limits}) {
    final f = File(p.join(tmp.path, name))..writeAsBytesSync(bytes);
    return prescanPdf(f.path, limits: limits ?? const PrescanLimits());
  }

  test('double-Flate bomb (256 MiB from a few KB) is refused', () async {
    final bomb = doubleFlate(256 << 20);
    expect(bomb.length, lessThan(4096));
    final r = await scanBytes('bomb.pdf', pdfWith(streamObj('/Filter [/FlateDecode /FlateDecode]', bomb)));
    expect(r.verdict, PrescanVerdict.unsafe, reason: '$r');
    expect(r.issue, PrescanIssue.decompressionBomb);
    expect(() => r.throwIfUnsafe(),
        throwsA(isA<DocumentOpenException>().having((e) => e.failure, 'failure', OpenFailure.unsafe)));
  });

  test('bomb with indirect /Length and abbreviated filter names is refused', () async {
    final bomb = doubleFlate(128 << 20);
    final r = await scanBytes('bomb2.pdf', pdfWith(streamObj('/Filter [/Fl /Fl]', bomb, lengthRef: true)));
    expect(r.verdict, PrescanVerdict.unsafe, reason: '$r');
  });

  test('single-layer Flate content within cap passes; large one over cap is refused', () async {
    final ok = ZLibEncoder().convert(Uint8List(8 << 20));
    expect((await scanBytes('ok.pdf', pdfWith(streamObj('/Filter /FlateDecode', ok)))).verdict, PrescanVerdict.ok);
    final big = ZLibEncoder().convert(Uint8List(80 << 20)); // ~80 KB raw -> 80 MiB
    final r = await scanBytes('big.pdf', pdfWith(streamObj('/Filter /FlateDecode', big)));
    expect(r.verdict, PrescanVerdict.unsafe, reason: '$r');
  });

  test('image streams may decode up to their declared size', () async {
    // 4000x3000 gray = 12 MB, declared; decodes to exactly that.
    final img = ZLibEncoder().convert(Uint8List(4000 * 3000));
    final dict = '/Type /XObject /Subtype /Image /Width 4000 /Height 3000 /ColorSpace /DeviceGray '
        '/BitsPerComponent 8 /Filter /FlateDecode';
    final r = await scanBytes('img.pdf', pdfWith(streamObj(dict, img)),
        limits: const PrescanLimits(maxStreamBytes: 1 << 20));
    expect(r.verdict, PrescanVerdict.ok, reason: '$r');
    // Same data claiming to be a 100x100 image exceeds its declared size.
    final lying = dict.replaceAll('/Width 4000 /Height 3000', '/Width 100 /Height 100');
    final r2 = await scanBytes('img2.pdf', pdfWith(streamObj(lying, img)),
        limits: const PrescanLimits(maxStreamBytes: 1 << 20));
    expect(r2.verdict, PrescanVerdict.unsafe, reason: '$r2');
  });

  test('absurd declared image size is refused without decoding', () async {
    final dict = '/Subtype /Image /Width 20000 /Height 20000 /ColorSpace /DeviceRGB /BitsPerComponent 8 '
        '/Filter /DCTDecode';
    final r = await scanBytes('hugeimg.pdf', pdfWith(streamObj(dict, [0xFF, 0xD8, 0xFF, 0xD9])));
    expect(r.issue, PrescanIssue.oversizedImage, reason: '$r');
  });

  test('nested LZW/RunLength chains are refused as unverifiable', () async {
    final r = await scanBytes('lzw.pdf', pdfWith(streamObj('/Filter [/FlateDecode /LZWDecode]', [1, 2, 3])));
    expect(r.issue, PrescanIssue.unverifiableNestedCompression);
  });

  test('corrupt Flate data and junk do not throw', () async {
    final rnd = Random(1);
    final junk = List.generate(5000, (_) => rnd.nextInt(256));
    expect((await scanBytes('bad.pdf', pdfWith(streamObj('/Filter [/FlateDecode /FlateDecode]', junk)))).verdict,
        PrescanVerdict.ok);
    expect((await scanBytes('junk.pdf', Uint8List.fromList(junk))).verdict, PrescanVerdict.ok);
    expect((await prescanPdf(p.join(tmp.path, 'missing.pdf'))).verdict, PrescanVerdict.incomplete);
  });

  test('time budget yields incomplete, not a hang', () async {
    final big = ZLibEncoder().convert(Uint8List(60 << 20));
    final r = await scanBytes('slow.pdf', pdfWith(streamObj('/Filter /FlateDecode', big)),
        limits: const PrescanLimits(timeBudget: Duration.zero));
    expect(r.verdict, PrescanVerdict.incomplete);
  });

  test('QA corpus: bombs refused, all other files allowed', () async {
    final dir = Directory('test_assets/pdfs/malformed');
    if (!dir.existsSync()) return;
    final unsafe = <String>[];
    for (final f in dir.listSync().whereType<File>()) {
      final r = await prescanPdf(f.path);
      if (r.isUnsafe) unsafe.add(p.basename(f.path));
    }
    expect(unsafe.toSet(), {'decompression_bomb.pdf', 'image_bomb.pdf'});
  });

  test('normal PDFs pass; measure overhead', () async {
    final files = <String>[
      ...Directory('test_assets/pdfs').listSync().whereType<File>().where((f) => f.path.endsWith('.pdf')).map((f) => f.path),
    ];
    // A large, legit, generated document: 300 text pages + a 2400x2400 noise image (Flate, ~17 MB).
    final doc = pw.Document();
    final rnd = Random(7);
    final noise = Uint8List.fromList(List.generate(2400 * 2400 * 4, (_) => rnd.nextInt(256)));
    final image = pw.RawImage(bytes: noise, width: 2400, height: 2400);
    doc.addPage(pw.Page(build: (_) => pw.Image(image)));
    for (var i = 0; i < 300; i++) {
      doc.addPage(pw.Page(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          build: (_) => pw.Text(List.generate(400, (j) => 'word$i-$j').join(' '))));
    }
    final big = File(p.join(tmp.path, 'generated_big.pdf'))..writeAsBytesSync(await doc.save());
    files.add(big.path);
    for (final path in files) {
      final r = await prescanPdf(path);
      expect(r.verdict, PrescanVerdict.ok, reason: '$path: $r');
      // ignore: avoid_print
      print('prescan ${p.basename(path)} (${File(path).lengthSync()} B): $r');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
