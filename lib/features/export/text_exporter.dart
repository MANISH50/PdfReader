import 'dart:convert';
import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

import '../../core/export/exporter.dart';
import '../../core/models/annotation.dart';
import '../../core/models/export_job.dart';
import '../../core/security/limits.dart';
import '../../core/storage/app_storage.dart';
import 'export_support.dart';

/// Loads the reading-order text of one page (seam for tests).
typedef PageTextLoader = Future<String> Function(PdfPage page);

/// pdfrx structured text: lines and direction segments in reading order,
/// generated spaces between words, `\n` between lines.
Future<String> loadStructuredPageText(PdfPage page) async =>
    (await page.loadStructuredText(ensureLoaded: true)).fullText;

/// Exports plain UTF-8 text. Each page starts with `--- Page N ---`; pages
/// after the first are preceded by a form feed so tools can split them.
class TextExporter implements Exporter {
  TextExporter(this.temp, {this.loadText = loadStructuredPageText});

  final TempFiles temp;
  final PageTextLoader loadText;

  static const String unreadablePage = '[Text on this page could not be read]';

  @override
  Set<ExportFormat> get formats => const {ExportFormat.txt};

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
    IOSink? sink;
    try {
      final pages = resolvePages(options.pages, doc.pages.length);
      if (pages.isEmpty) throw const ExportFailure('No pages to export.');
      final path = out.path('${sanitizeBaseName(baseName)}.txt');
      sink = File(path).openWrite(encoding: utf8);
      onProgress?.call(0, pages.length);
      for (var i = 0; i < pages.length; i++) {
        throwIfCancelled(isCancelled);
        final n = pages[i];
        final text = await _pageText(doc, n);
        throwIfCancelled(isCancelled);
        sink.write(formatPage(n, text, first: i == 0));
        onProgress?.call(i + 1, pages.length);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return ExportResult([path]);
    } catch (e) {
      await sink?.close().catchError((_) {});
      await out.discard();
      if (e is ExportCancelledException || e is ExportFailure) rethrow;
      throw ExportFailure('The text could not be extracted.', e);
    }
  }

  Future<String?> _pageText(PdfDocument doc, int n) async {
    try {
      final page = await loadedPage(doc, n);
      if (page == null) return null;
      return await loadText(page).timeout(SecurityLimits.pageTextTimeout);
    } catch (_) {
      return null; // one bad page must not fail the whole export
    }
  }

  /// Formats one page block. [text] null means extraction failed.
  static String formatPage(int pageNumber, String? text, {required bool first}) {
    final b = StringBuffer();
    if (!first) b.write('\f');
    b.write('--- Page $pageNumber ---\n');
    if (text == null) {
      b.write('$unreadablePage\n');
    } else {
      final clean = cleanText(text);
      if (clean.isNotEmpty) b.write('$clean\n');
    }
    b.write('\n');
    return b.toString();
  }

  /// Normalises line endings, removes control characters (keeping tabs and
  /// newlines), trims trailing spaces and caps the length per page. Unicode
  /// (RTL scripts, Devanagari, combining marks) is kept as is.
  static String cleanText(String text) {
    var t = truncateUtf16(text, SecurityLimits.maxCharsPerPage);
    t = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    t = t.replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F\uFFFE\uFFFF]'), '');
    t = t.split('\n').map((l) => l.trimRight()).join('\n');
    return t.trim();
  }
}
