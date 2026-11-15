import 'dart:io';
import 'dart:isolate';

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
/// with (almost) no text but graphic content, so scanned content is not lost.
///
/// Page images are written to the export directory as they are rendered and
/// streamed into the zip; only file paths are kept in memory.
class DocxExporter implements Exporter {
  DocxExporter(
    this.temp, {
    this.loadText = loadRawPageText,
    this.probe = pdfiumPageProbe,
    this.embedImagesForScans = true,
    this.scanImageDpi = 150,
    this.maxEmbeddedImages = 500,
  });

  final TempFiles temp;
  final RawTextLoader loadText;

  /// Font styles and graphics detection; null disables both (unstyled text,
  /// every near-empty page treated as having graphics).
  final PageProber? probe;
  final bool embedImagesForScans;
  final int scanImageDpi;

  /// Upper bound on embedded page images per document (output size guard).
  final int maxEmbeddedImages;

  /// Pages with fewer visible characters than this are treated as scans.
  static const int scanTextThreshold = 16;

  static String imageCapNotice(int cap) =>
      'Only the first $cap image-only pages were included as pictures; the others are marked in the document.';
  static String imageCapPlaceholder(int page) => '[Page $page: picture not included (too many image pages)]';

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
      final mediaDir = Directory(out.path('.media'))..createSync();
      final pages = <DocxPage>[];
      final notices = <String>[];
      var images = 0;
      onProgress?.call(0, pageNumbers.length);
      for (var i = 0; i < pageNumbers.length; i++) {
        throwIfCancelled(isCancelled);
        final n = pageNumbers[i];
        final page = await loadedPage(doc, n);
        var paragraphs = <TextParagraph>[];
        DocxImage? image;
        if (page != null) {
          final (paras, hasGraphics) = await _analyzePage(doc, page);
          paragraphs = paras;
          throwIfCancelled(isCancelled);
          final visible = paragraphs.fold<int>(0, (s, p) => s + p.text.replaceAll(RegExp(r'\s'), '').length);
          if (embedImagesForScans && visible < scanTextThreshold && hasGraphics) {
            if (images < maxEmbeddedImages) {
              image = await _pageImage(page, '${mediaDir.path}/p$n.jpeg', isCancelled);
              if (image != null) images++;
            } else {
              if (notices.isEmpty) notices.add(imageCapNotice(maxEmbeddedImages));
              paragraphs = [
                TextParagraph(runs: [TextRun(imageCapPlaceholder(n))], fontSize: 0, rtl: false, lineCount: 1),
                ...paragraphs,
              ];
            }
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
      final path = out.path('$base.docx');
      await _buildDocx(pages, base, path);
      throwIfCancelled(isCancelled);
      await mediaDir.delete(recursive: true);
      return ExportOutcome([path], notices: notices);
    } catch (e) {
      await out.discard();
      if (e is ExportCancelledException || e is ExportFailure) rethrow;
      throw ExportFailure('The document could not be converted to Word.', e);
    }
  }

  /// Paragraphs of a page and whether it has graphic content.
  Future<(List<TextParagraph>, bool)> _analyzePage(PdfDocument doc, PdfPage page) async {
    try {
      final raw = await loadText(page).timeout(SecurityLimits.pageTextTimeout);
      var text = raw?.text ?? '';
      var boxes = raw?.boxes ?? const <CharBox?>[];
      if (text.length > SecurityLimits.maxCharsPerPage) {
        text = truncateUtf16(text, SecurityLimits.maxCharsPerPage);
        if (boxes.length > text.length) boxes = boxes.sublist(0, text.length);
      }
      final info = probe == null
          ? null
          : await probe!(doc, page.pageNumber, raw?.text ?? '')
              .timeout(SecurityLimits.pageTextTimeout, onTimeout: () => null);
      final hasGraphics = info?.hasGraphics ?? true;
      if (text.isEmpty) return (<TextParagraph>[], hasGraphics);
      final styles = text.length == (raw?.text.length ?? -1) ? info?.styles : null;
      final chars = buildPageChars(text, boxes, styles);
      return (await _analyze(chars), hasGraphics);
    } catch (_) {
      return (<TextParagraph>[], true); // unreadable page: keep going, the page may get an image
    }
  }

  Future<DocxImage?> _pageImage(PdfPage page, String path, bool Function()? isCancelled) async {
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
      await File(path).writeAsBytes(jpeg, flush: true);
      return DocxImage(path, pixelWidth: w, pixelHeight: h);
    } on ExportCancelledException {
      rethrow;
    } catch (_) {
      return null;
    }
  }
}

// Isolate entry points are top-level so closures capture only their arguments.
Future<List<TextParagraph>> _analyze(List<PageChar> chars) => Isolate.run(() => analyzePage(chars));

Future<void> _buildDocx(List<DocxPage> pages, String title, String outPath) => Isolate.run(() {
      classifyHeadings([for (final p in pages) p.paragraphs]);
      final body = bodyFontSize(pages.expand((p) => p.paragraphs));
      DocxWriter.writeZip(DocxWriter(title: title).buildParts(pages, body), outPath);
    });
