import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../core/export/exporter.dart';
import '../../core/models/annotation.dart';
import '../../core/models/export_job.dart';
import '../../core/security/limits.dart';
import '../../core/storage/app_storage.dart';
import 'docx/char_style_probe.dart';
import 'docx/docx_writer.dart';
import 'docx/layout.dart';
import 'export_support.dart';
import 'image_exporter.dart';

/// Raw page text with one box per engine character.
class RawPageText {
  const RawPageText(this.text, this.boxes);
  final String text;
  final List<CharBox?> boxes;
}

typedef RawTextLoader = Future<RawPageText?> Function(PdfPage page);

Future<RawPageText?> loadRawPageText(PdfPage page) async {
  final raw = await page.loadText();
  if (raw == null) return null;
  return RawPageText(raw.fullText, [for (final r in raw.charRects) CharBox(r.left, r.top, r.right, r.bottom)]);
}

/// Converts pages to a DOCX: paragraphs rebuilt from character positions,
/// headings by relative font size, bold/italic when PDFium reports them,
/// RTL paragraphs, page breaks between pages, and a page image for pages
/// with (almost) no text so scanned content is not lost.
class DocxExporter implements Exporter {
  DocxExporter(
    this.temp, {
    this.loadText = loadRawPageText,
    this.probeStyles = pdfiumCharStyleProbe,
    this.embedImagesForScans = true,
    this.scanImageDpi = 150,
  });

  final TempFiles temp;
  final RawTextLoader loadText;
  final CharStyleProbe? probeStyles;
  final bool embedImagesForScans;
  final int scanImageDpi;

  /// Pages with fewer visible characters than this are treated as scans.
  static const int scanTextThreshold = 16;

  /// Upper bound on embedded page images per document (memory/size guard).
  static const int maxEmbeddedImages = 200;

  @override
  Set<ExportFormat> get formats => const {ExportFormat.docx};

  @override
  Future<ExportResult> export(
    PdfDocument doc,
    ExportOptions options, {
    required String baseName,
    List<Annotation> annotations = const [],
    ExportProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = ExportOutput(temp);
    try {
      final pageNumbers = resolvePages(options.pages, doc.pages.length);
      if (pageNumbers.isEmpty) throw const ExportFailure('No pages to export.');
      final base = sanitizeBaseName(baseName);
      final pages = <DocxPage>[];
      var images = 0;
      onProgress?.call(0, pageNumbers.length);
      for (var i = 0; i < pageNumbers.length; i++) {
        throwIfCancelled(isCancelled);
        final n = pageNumbers[i];
        final page = await loadedPage(doc, n);
        var paragraphs = <TextParagraph>[];
        DocxImage? image;
        if (page != null) {
          paragraphs = await _paragraphs(doc, page);
          throwIfCancelled(isCancelled);
          final visible = paragraphs.fold<int>(0, (s, p) => s + p.text.replaceAll(RegExp(r'\s'), '').length);
          if (embedImagesForScans && visible < scanTextThreshold && images < maxEmbeddedImages) {
            image = await _pageImage(page, isCancelled);
            if (image != null) images++;
          }
        }
        pages.add(DocxPage(
          paragraphs: paragraphs,
          widthPt: page?.width ?? 612,
          heightPt: page?.height ?? 792,
          image: image,
        ));
        onProgress?.call(i + 1, pageNumbers.length);
      }
      throwIfCancelled(isCancelled);
      final bytes = await _buildDocx(pages, base);
      throwIfCancelled(isCancelled);
      final path = out.path('$base.docx');
      await File(path).writeAsBytes(bytes, flush: true);
      return ExportResult([path]);
    } catch (e) {
      await out.discard();
      if (e is ExportCancelledException || e is ExportFailure) rethrow;
      throw ExportFailure('The document could not be converted to Word.', e);
    }
  }

  Future<List<TextParagraph>> _paragraphs(PdfDocument doc, PdfPage page) async {
    try {
      final raw = await loadText(page).timeout(SecurityLimits.pageTextTimeout);
      if (raw == null || raw.text.isEmpty) return [];
      var text = raw.text;
      var boxes = raw.boxes;
      if (text.length > SecurityLimits.maxCharsPerPage) {
        text = truncateUtf16(text, SecurityLimits.maxCharsPerPage);
        if (boxes.length > text.length) boxes = boxes.sublist(0, text.length);
      }
      List<CharStyle?>? styles;
      if (probeStyles != null && text.length == raw.text.length) {
        styles = await probeStyles!(doc, page.pageNumber, text)
            .timeout(SecurityLimits.pageTextTimeout, onTimeout: () => null);
      }
      final chars = buildPageChars(text, boxes, styles);
      return await _analyze(chars);
    } catch (_) {
      return []; // unreadable page text: keep going, the page may get an image
    }
  }

  Future<DocxImage?> _pageImage(PdfPage page, bool Function()? isCancelled) async {
    try {
      final size = RenderSize.compute(page.width, page.height, scanImageDpi, maxPixels: 8 * 1024 * 1024);
      final image = await renderPage(page, size, isCancelled: isCancelled);
      final int w = image.width, h = image.height;
      final TransferableTypedData px;
      try {
        px = TransferableTypedData.fromList([image.pixels]);
      } finally {
        image.dispose();
      }
      final jpeg = await ImageExporter.encodeBgra(px, w, h, ExportFormat.jpg, 80);
      return DocxImage(Uint8List.fromList(jpeg), pixelWidth: w, pixelHeight: h);
    } on ExportCancelledException {
      rethrow;
    } catch (_) {
      return null;
    }
  }
}

// Isolate entry points are top-level so closures capture only their arguments.
Future<List<TextParagraph>> _analyze(List<PageChar> chars) => Isolate.run(() => analyzePage(chars));

Future<Uint8List> _buildDocx(List<DocxPage> pages, String title) => Isolate.run(() {
      classifyHeadings([for (final p in pages) p.paragraphs]);
      final body = bodyFontSize(pages.expand((p) => p.paragraphs));
      return DocxWriter.zip(DocxWriter(title: title).buildParts(pages, body));
    });
