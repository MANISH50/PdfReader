import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfium_dart/pdfium_dart.dart' show FPDF_ANNOT_TEXT, FPDF_DOCUMENT;
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/pdf/page_editor.dart';
import 'package:pdfreader/features/editor/engine/pdfium_native.dart';
import 'package:pdfreader/features/editor/engine/pdfrx_page_editor.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_fixtures.dart';

Future<PdfDocument> open(List<int> bytes) => PdfDocument.openData(Uint8List.fromList(bytes));

Future<String> pageText(PdfDocument d, int n) async => (await d.pages[n - 1].loadText())?.fullText ?? '';

/// Renders page [n] at 1 px per point; returns a sampler (PDF coords → BGRA).
Future<List<int> Function(double x, double y)> renderPage(PdfDocument d, int n) async {
  final page = d.pages[n - 1];
  final w = page.width.round(), h = page.height.round();
  final image = (await page.render(
      width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xFFFFFFFF))!;
  final px = Uint8List.fromList(image.pixels);
  image.dispose();
  return (double x, double y) {
    final int i = (((h - y.round()) * w + x.round()) * 4).toInt();
    return px.sublist(i, i + 4); // B G R A
  };
}

int countTextAnnots(FPDF_DOCUMENT doc, Object? _) {
  final p = NativePdf.pdfium;
  final page = p.FPDF_LoadPage(doc, 0);
  var n = 0;
  for (var i = 0; i < p.FPDFPage_GetAnnotCount(page); i++) {
    final a = p.FPDFPage_GetAnnot(page, i);
    if (p.FPDFAnnot_GetSubtype(a) == FPDF_ANNOT_TEXT) n++;
    p.FPDFPage_CloseAnnot(a);
  }
  p.FPDF_ClosePage(page);
  return n;
}

bool isLoaded(FPDF_DOCUMENT doc, Object? _) => doc != nullptr;

void main() {
  setUpAll(() async => pdfrxInitialize());

  final editor = PdfrxPageEditor();

  test('rebuild reorders, deletes and rotates', () async {
    final src = await open(await makePdf(3));
    final out = await open(await editor.rebuild(src, const [
      PageSpec(3, rotationDegrees: 90),
      PageSpec(1),
    ]));
    expect(out.pages.length, 2);
    expect(out.pages[0].rotation, PdfPageRotation.clockwise90);
    expect(out.pages[0].width, greaterThan(out.pages[0].height));
    expect(out.pages[1].rotation, PdfPageRotation.none);
    expect(await pageText(out, 1), contains('Page 3'));
    expect(await pageText(out, 2), contains('Page 1'));
    // Source untouched.
    expect(src.pages.length, 3);
    expect(await pageText(src, 1), contains('Page 1'));
    await out.dispose();
    await src.dispose();
  });

  test('rebuild keeping all pages (reorder only) and relative rotation', () async {
    final src = await open(await makePdf(3));
    final first = await open(await editor.rebuild(src, const [PageSpec(2, rotationDegrees: 180), PageSpec(1), PageSpec(3)]));
    expect(first.pages.length, 3);
    expect(await pageText(first, 1), allOf(contains('2'), isNot(contains('1')))); // 180° page text reads reversed
    expect(await pageText(first, 2), contains('Page 1'));
    expect(await pageText(first, 3), contains('Page 3'));
    final dup = await open(await editor.rebuild(src, const [PageSpec(1), PageSpec(2), PageSpec(3), PageSpec(1)]));
    expect(dup.pages.length, 4);
    expect(await pageText(dup, 4), contains('Page 1'));
    await dup.dispose();
    expect(first.pages[0].rotation, PdfPageRotation.clockwise180);
    // Rotation is relative: +270 on a 180° page → 90°.
    final second = await open(await editor.rebuild(first, const [PageSpec(1, rotationDegrees: 270)]));
    expect(second.pages.single.rotation, PdfPageRotation.clockwise90);
    expect(() => editor.rebuild(src, const [PageSpec(9)]), throwsA(isA<PageEditException>()));
    expect(() => editor.rebuild(src, const [PageSpec(1, rotationDegrees: 45)]), throwsA(isA<PageEditException>()));
    for (final d in [src, first, second]) {
      await d.dispose();
    }
  });

  test('merge concatenates documents in order', () async {
    final a = await open(await makePdf(2, prefix: 'Alpha'));
    final b = await open(await makePdf(3, prefix: 'Beta'));
    final out = await open(await editor.merge([a, b]));
    expect(out.pages.length, 5);
    expect(await pageText(out, 2), contains('Alpha 2'));
    expect(await pageText(out, 3), contains('Beta 1'));
    expect(await pageText(out, 5), contains('Beta 3'));
    for (final d in [a, b, out]) {
      await d.dispose();
    }
  });

  test('split by ranges', () async {
    final src = await open(await makePdf(5));
    final parts = await editor.split(src, const [
      [1, 2],
      [3],
      [5, 4],
    ]);
    expect(parts, hasLength(3));
    final docs = [for (final p in parts) await open(p)];
    expect([for (final d in docs) d.pages.length], [2, 1, 2]);
    expect(await pageText(docs[2], 1), contains('Page 5'));
    // Dropped pages do not leak into a split part.
    expect(String.fromCharCodes(parts[1]).contains('Page 1'), isFalse);
    for (final d in [src, ...docs]) {
      await d.dispose();
    }
  });

  test('flatten burns every annotation type and reopens', () async {
    // Opaque red 40x20 signature with a transparent right half.
    final sig = img.Image(width: 40, height: 20, numChannels: 4);
    for (var y = 0; y < 20; y++) {
      for (var x = 0; x < 40; x++) {
        sig.setPixelRgba(x, y, 255, 0, 0, x < 20 ? 255 : 0);
      }
    }
    final png = Uint8List.fromList(img.encodePng(sig));
    final flattener = PdfrxPageEditor(loadSignature: (id) async => id == 'sig1' ? png : null);

    final src = await open(await makePdf(2));
    final now = DateTime(2026);
    final annotations = <Annotation>[
      TextMarkupAnnotation(id: 'h', page: 1, color: const Color(0xFF00FF00), createdAt: now,
          kind: MarkupKind.highlight, rects: [const Rect.fromLTRB(100, 500, 200, 520)]),
      const TextMarkupAnnotation(id: 'u', page: 1, color: Color(0xFF0000FF),
          kind: MarkupKind.underline, rects: [Rect.fromLTRB(100, 450, 200, 470)]),
      const TextMarkupAnnotation(id: 's', page: 1, color: Color(0xFF0000FF),
          kind: MarkupKind.strikeout, rects: [Rect.fromLTRB(100, 400, 200, 420)]),
      const NoteAnnotation(id: 'n', page: 1, color: Color(0xFFFFD400), anchor: Offset(50, 700), text: 'Hello note'),
      const InkAnnotation(id: 'i', page: 1, color: Color(0xFF000000), strokeWidth: 4, strokes: [
        [Offset(300, 300), Offset(320, 310), Offset(340, 300), Offset(360, 310)]
      ]),
      const ShapeAnnotation(id: 'r', page: 1, color: Color(0xFFFF0000), shape: ShapeKind.rectangle,
          bounds: Rect.fromLTRB(300, 600, 400, 700), strokeWidth: 3),
      const ShapeAnnotation(id: 'e', page: 1, color: Color(0xFFFF0000), shape: ShapeKind.ellipse,
          bounds: Rect.fromLTRB(420, 600, 520, 700), strokeWidth: 3),
      const ShapeAnnotation(id: 'a', page: 2, color: Color(0xFF000000), shape: ShapeKind.arrow,
          bounds: Rect.fromLTRB(100, 100, 300, 300), strokeWidth: 2),
      const TextBoxAnnotation(id: 't', page: 2, color: Color(0xFF000000),
          bounds: Rect.fromLTRB(100, 600, 400, 700), text: 'Flattened words', fontSize: 14),
      const TextBoxAnnotation(id: 't2', page: 2, color: Color(0xFF000000),
          bounds: Rect.fromLTRB(100, 400, 400, 450), text: '日本語', fontSize: 14),
      const SignatureAnnotation(id: 'g', page: 2, color: Color(0xFF000000),
          bounds: Rect.fromLTRB(300, 200, 380, 240), signatureId: 'sig1'),
      const InkAnnotation(id: 'bad', page: 99, color: Color(0xFF000000), strokeWidth: 1, strokes: []),
    ];
    final bytes = await flattener.flatten(src, annotations);
    final out = await open(bytes);
    expect(out.pages.length, 2);

    final p1 = await renderPage(out, 1);
    final hl = p1(150, 510);
    expect(hl[1], greaterThan(200)); // green channel stays high
    expect(hl[2], lessThan(220)); // red reduced by green highlight (multiply)
    expect(p1(150, 451)[0], greaterThan(150)); // underline: blue
    expect(p1(150, 451)[2], lessThan(100));
    expect(p1(300, 650)[2], greaterThan(200)); // rect left edge red
    expect(p1(300, 650)[0], lessThan(100));
    expect(p1(350, 650), [255, 255, 255, 255]); // rect interior untouched

    final p2 = await renderPage(out, 2);
    expect(p2(310, 220)[2], greaterThan(200)); // opaque half of signature is red
    expect(p2(310, 220)[1], lessThan(60));
    expect(p2(370, 220), [255, 255, 255, 255]); // transparent half stays white
    expect(await pageText(out, 2), contains('Flattened words'));
    // CJK text rasterised: something is drawn in that box.
    var inked = false;
    for (var x = 100; x < 200 && !inked; x += 2) {
      for (var y = 420; y < 450 && !inked; y += 2) {
        if (p2(x.toDouble(), y.toDouble())[0] < 200) inked = true;
      }
    }
    expect(inked, isTrue);

    // The note became a real /Text annotation on page 1.
    final textAnnots = await NativePdf.read(bytes, null, countTextAnnots);
    expect(textAnnots, 1);
    expect(src.pages.length, 2);
    await out.dispose();
    await src.dispose();
  });

  test('flatten with no annotations returns a valid copy', () async {
    final src = await open(await makePdf(1));
    final out = await open(await editor.flatten(src, const []));
    expect(out.pages.length, 1);
    await out.dispose();
    await src.dispose();
  });

  test('NativePdf rejects garbage bytes without crashing', () async {
    final lock = await open(await makePdf(1));
    await expectLater(
        NativePdf.read(Uint8List.fromList(List.filled(100, 7)), null, isLoaded), throwsA(isA<PdfException>()));
    await lock.dispose();
  });
}
