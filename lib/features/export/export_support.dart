import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../core/security/limits.dart';
import '../../core/storage/app_storage.dart';

/// Thrown when the user cancelled an export. Partial output is removed.
class ExportCancelledException implements Exception {
  const ExportCancelledException();
  @override
  String toString() => 'ExportCancelledException';
}

/// An export failure with a message that is safe to show to the user
/// (never raw engine/exception text).
class ExportFailure implements Exception {
  const ExportFailure(this.userMessage, [this.cause]);
  final String userMessage;
  final Object? cause;
  @override
  String toString() => 'ExportFailure($userMessage${cause == null ? '' : ', $cause'})';
}

/// Throws [ExportCancelledException] when [isCancelled] reports true.
void throwIfCancelled(bool Function()? isCancelled) {
  if (isCancelled != null && isCancelled()) throw const ExportCancelledException();
}

/// Makes [name] safe for use as a file name: no path separators or control
/// characters, no leading dots, bounded length. Unicode letters are kept.
String sanitizeBaseName(String name) {
  var s = name.replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_').trim();
  s = s.replaceFirst(RegExp(r'^\.+'), '');
  if (s.runes.length > 80) s = String.fromCharCodes(s.runes.take(80));
  s = s.trim();
  return s.isEmpty ? 'document' : s;
}

/// Cuts [s] to at most [max] UTF-16 units without splitting a surrogate pair.
String truncateUtf16(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  final u = s.codeUnitAt(end - 1);
  if (u >= 0xD800 && u <= 0xDBFF) end--;
  return s.substring(0, end);
}

/// `<base>_p<NNN>.<ext>`, zero-padded to at least 3 digits.
String pageFileName(String base, int pageNumber, String ext) =>
    '${base}_p${pageNumber.toString().padLeft(3, '0')}.$ext';

/// Resolves 1-based [pages] against [pageCount]: null means all pages; invalid
/// and duplicate numbers are dropped, order is kept.
List<int> resolvePages(List<int>? pages, int pageCount) {
  if (pages == null) return [for (var i = 1; i <= pageCount; i++) i];
  final seen = <int>{};
  return [
    for (final n in pages)
      if (n >= 1 && n <= pageCount && seen.add(n)) n
  ];
}

/// Pixel size for rendering a page at a given DPI, scaled down to respect
/// the pixel budget and a per-side limit (JPEG/PNG encoders cap at 65535).
class RenderSize {
  const RenderSize(this.width, this.height, this.scaledDown);
  final int width;
  final int height;

  /// True when the requested DPI exceeded the pixel cap.
  final bool scaledDown;

  static const int minDpi = 36;
  static const int maxDpi = 1200;
  static const int maxSide = 32000;

  static RenderSize compute(
    double widthPt,
    double heightPt,
    int dpi, {
    int maxPixels = SecurityLimits.maxRenderPixels,
  }) {
    final wPt = widthPt.isFinite && widthPt > 0 ? math.min(widthPt, SecurityLimits.maxPageSidePt) : 612.0;
    final hPt = heightPt.isFinite && heightPt > 0 ? math.min(heightPt, SecurityLimits.maxPageSidePt) : 792.0;
    final d = dpi.clamp(minDpi, maxDpi);
    var w = wPt * d / 72;
    var h = hPt * d / 72;
    var scaled = false;
    if (w * h > maxPixels) {
      final s = math.sqrt(maxPixels / (w * h));
      w *= s;
      h *= s;
      scaled = true;
    }
    final side = math.max(w, h);
    if (side > maxSide) {
      final s = maxSide / side;
      w *= s;
      h *= s;
      scaled = true;
    }
    return RenderSize(math.max(1, w.floor()), math.max(1, h.floor()), scaled);
  }
}

/// Creates the per-export output directory and removes it again on failure.
class ExportOutput {
  ExportOutput(TempFiles temp) : dir = temp.createDir();
  final Directory dir;

  String path(String fileName) => p.join(dir.path, fileName);

  Future<void> discard() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // best effort; TempFiles.wipe() at next start will get it
    }
  }
}

/// Makes sure [page] is loaded (progressively loaded documents), bounded by
/// a timeout. Returns null when it could not be loaded.
Future<PdfPage?> loadedPage(PdfDocument doc, int pageNumber) async {
  final page = doc.pages[pageNumber - 1];
  if (page.isLoaded) return page;
  return page.waitForLoaded(timeout: SecurityLimits.pageRenderTimeout);
}

/// Renders a page to BGRA pixels with timeout and cancellation. The returned
/// image must be disposed by the caller.
Future<PdfImage> renderPage(
  PdfPage page,
  RenderSize size, {
  bool withAnnotations = true,
  bool Function()? isCancelled,
}) async {
  final token = page.createCancellationToken();
  final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (isCancelled != null && isCancelled()) token.cancel();
  });
  try {
    final image = await page
        .render(
          width: size.width,
          height: size.height,
          fullWidth: size.width.toDouble(),
          fullHeight: size.height.toDouble(),
          backgroundColor: 0xFFFFFFFF,
          annotationRenderingMode:
              withAnnotations ? PdfAnnotationRenderingMode.annotationAndForms : PdfAnnotationRenderingMode.none,
          cancellationToken: token,
        )
        .timeout(SecurityLimits.pageRenderTimeout, onTimeout: () {
      token.cancel();
      return null;
    });
    throwIfCancelled(isCancelled);
    if (image == null) {
      throw ExportFailure('Page ${page.pageNumber} could not be rendered.');
    }
    return image;
  } finally {
    poll.cancel();
  }
}
