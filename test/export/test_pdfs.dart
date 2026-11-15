import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset;

import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfrx/pdfrx.dart';

bool _initialized = false;

/// Initialises pdfrx's pure-Dart engine for `flutter test` (PDFium comes from
/// pdfium_dart's bundled native asset).
Future<void> initEngine() async {
  if (_initialized) return;
  await pdfrxInitialize();
  _initialized = true;
}

/// A multi-page document with a heading, body paragraphs, bold/italic text
/// and different font sizes. Page 3 is intentionally blank (like a scan).
Future<Uint8List> buildSamplePdf({int pages = 3, PdfPageFormat format = PdfPageFormat.a4}) async {
  final d = pw.Document();
  const body = 'The quick brown fox jumps over the lazy dog while the export pipeline turns this '
      'paragraph into Word text with sensible line joining and wrapping across several lines.';
  for (var i = 1; i <= pages; i++) {
    d.addPage(pw.Page(
      pageFormat: format,
      build: (c) => i == 3
          ? pw.SizedBox()
          : pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Chapter $i Title', style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 14),
              pw.Text('$body First.', style: const pw.TextStyle(fontSize: 11)),
              pw.SizedBox(height: 14),
              pw.Text('Section $i.1', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Text('$body Second.', style: const pw.TextStyle(fontSize: 11)),
              pw.SizedBox(height: 14),
              pw.Text('Emphasised sentence on page $i.',
                  style: pw.TextStyle(fontSize: 11, fontStyle: pw.FontStyle.italic)),
            ]),
    ));
  }
  return d.save();
}

/// One page of the given size in points with a line of text.
Future<Uint8List> buildSizedPdf(double widthPt, double heightPt) async {
  final d = pw.Document();
  d.addPage(pw.Page(
    pageFormat: PdfPageFormat(widthPt, heightPt),
    build: (c) => pw.Text('Hi'),
  ));
  return d.save();
}

Future<PdfDocument> openBytes(Uint8List bytes) => PdfDocument.openData(bytes, sourceName: 'test-${bytes.hashCode}');

/// A fresh TempFiles rooted in a system temp directory, deleted after use.
TempFiles newTemp() => TempFiles(Directory.systemTemp.createTempSync('export_test_'));

Annotation fakeAnnotation({int page = 1}) =>
    NoteAnnotation(id: 'n$page', page: page, color: const Color(0xFFFFEB3B), anchor: const Offset(10, 10), text: 'note');
