import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../../core/export/exporter.dart';
import '../../core/models/annotation.dart';
import '../../core/models/export_job.dart';
import '../../core/storage/app_storage.dart';
import 'export_support.dart';

/// Burns app annotations into a copy of the document (PageEditor.flatten).
typedef Flattener = Future<List<int>> Function(PdfDocument doc, List<Annotation> annotations);

/// Opens PDF bytes produced during export (injectable for tests).
typedef PdfBytesOpener = Future<PdfDocument> Function(Uint8List bytes);

Future<PdfDocument> openPdfBytes(Uint8List bytes) =>
    PdfDocument.openData(bytes, sourceName: 'export-${DateTime.now().microsecondsSinceEpoch}');

/// Renders pages to PNG or JPG, one file per page: `<base>_p<NNN>.<ext>`.
/// Rendering honours the DPI request but is scaled down to the pixel cap;
/// encoding runs on a background isolate.
class ImageExporter implements Exporter {
  ImageExporter(this.temp, {this.flatten, this.open = openPdfBytes});

  final TempFiles temp;
  final Flattener? flatten;
  final PdfBytesOpener open;

  @override
  Set<ExportFormat> get formats => const {ExportFormat.png, ExportFormat.jpg};

  @override
  Future<ExportResult> export(
    PdfDocument doc,
    ExportOptions options, {
    required String baseName,
    List<Annotation> annotations = const [],
    ExportProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!formats.contains(options.format)) throw ArgumentError.value(options.format, 'format');
    final base = sanitizeBaseName(baseName);
    final out = ExportOutput(temp);
    PdfDocument? flattened;
    try {
      final pages = resolvePages(options.pages, doc.pages.length);
      if (pages.isEmpty) throw const ExportFailure('No pages to export.');
      var source = doc;
      final notices = <String>[];
      if (options.includeAnnotations && annotations.isNotEmpty) {
        final flattenedBytes = await _tryFlatten(doc, annotations);
        throwIfCancelled(isCancelled);
        if (flattenedBytes == null) {
          notices.add(annotationsSkippedNotice);
        } else {
          flattened = source = await open(Uint8List.fromList(flattenedBytes));
        }
      }
      final files = <String>[];
      onProgress?.call(0, pages.length);
      for (var i = 0; i < pages.length; i++) {
        throwIfCancelled(isCancelled);
        final n = pages[i];
        final page = await loadedPage(source, n);
        if (page == null) throw ExportFailure('Page $n could not be loaded.');
        final size = RenderSize.compute(page.width, page.height, options.dpi);
        final image = await renderPage(page, size, isCancelled: isCancelled);
        final TransferableTypedData pixels;
        final int w = image.width, h = image.height;
        try {
          pixels = TransferableTypedData.fromList([image.pixels]);
        } finally {
          image.dispose();
        }
        final bytes = await encodeBgra(pixels, w, h, options.format, options.jpgQuality);
        throwIfCancelled(isCancelled);
        final path = out.path(pageFileName(base, n, options.format.extension));
        await File(path).writeAsBytes(bytes, flush: true);
        files.add(path);
        onProgress?.call(i + 1, pages.length);
      }
      return ExportOutcome(files, notices: notices);
    } catch (e) {
      await out.discard();
      if (e is ExportCancelledException || e is ExportFailure) rethrow;
      throw ExportFailure('The pages could not be converted to images.', e);
    } finally {
      await flattened?.dispose();
    }
  }

  static const annotationsSkippedNotice =
      "Your annotations couldn't be added, so the images show the pages without them.";

  /// Flattened PDF bytes, or null when annotations can't be applied (editor
  /// unavailable or failing); the export then continues without them.
  Future<List<int>?> _tryFlatten(PdfDocument doc, List<Annotation> annotations) async {
    final f = flatten;
    if (f == null) return null;
    try {
      final bytes = await f(doc, annotations);
      return bytes.length >= 5 && String.fromCharCodes(bytes.take(5)) == '%PDF-' ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  /// Encodes BGRA pixels on a background isolate. The page is rendered on a
  /// white background, so the alpha channel is dropped.
  static Future<Uint8List> encodeBgra(
    TransferableTypedData pixels,
    int width,
    int height,
    ExportFormat format,
    int jpgQuality,
  ) {
    final quality = jpgQuality.clamp(1, 100);
    return Isolate.run(() {
      final data = pixels.materialize().asUint8List();
      final rgba = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: data.buffer,
        bytesOffset: data.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      );
      final rgb = rgba.convert(numChannels: 3);
      return switch (format) {
        ExportFormat.jpg => img.encodeJpg(rgb, quality: quality),
        ExportFormat.png => img.encodePng(rgb),
        _ => throw ArgumentError.value(format, 'format'),
      };
    });
  }
}
