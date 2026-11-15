import 'dart:io';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../core/export/exporter.dart';
import '../../core/models/annotation.dart';
import '../../core/models/export_job.dart';
import '../../core/pdf/page_editor.dart';
import '../../core/storage/app_storage.dart';
import 'export_support.dart';
import 'image_exporter.dart';

/// Exports a PDF with the user's annotations burnt in ([PageEditor.flatten])
/// and/or a subset of pages ([PageEditor.rebuild]). The original file is
/// never modified.
class PdfExporter implements Exporter {
  PdfExporter(this.temp, this.editor, {this.open = openPdfBytes});

  final TempFiles temp;

  /// Resolved lazily so a missing implementation surfaces as an export error.
  final PageEditor Function() editor;
  final PdfBytesOpener open;

  @override
  Set<ExportFormat> get formats => const {ExportFormat.pdf};

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
    PdfDocument? flattened;
    try {
      final pageCount = doc.pages.length;
      final pages = resolvePages(options.pages, pageCount);
      if (pages.isEmpty) throw const ExportFailure('No pages to export.');
      final PageEditor pe;
      try {
        pe = editor();
      } catch (e) {
        throw ExportFailure(editorUnavailable, e);
      }
      onProgress?.call(0, 2);
      final flatten = options.includeAnnotations && annotations.isNotEmpty;
      final List<int> bytes;
      if (flatten) {
        final selected = pages.toSet();
        final List<int> full;
        try {
          full = await pe.flatten(doc, [for (final a in annotations) if (selected.contains(a.page)) a]);
        } catch (e) {
          throw ExportFailure(flattenFailed, e);
        }
        throwIfCancelled(isCancelled);
        onProgress?.call(1, 2);
        if (_isAll(pages, pageCount)) {
          bytes = full;
        } else {
          flattened = await open(Uint8List.fromList(full));
          bytes = await pe.rebuild(flattened, [for (final n in pages) PageSpec(n)]);
        }
      } else {
        onProgress?.call(1, 2);
        bytes = await pe.rebuild(doc, [for (final n in pages) PageSpec(n)]);
      }
      throwIfCancelled(isCancelled);
      if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
        throw const ExportFailure('The PDF could not be created.');
      }
      final path = out.path('${sanitizeBaseName(baseName)}.pdf');
      await File(path).writeAsBytes(bytes, flush: true);
      onProgress?.call(2, 2);
      return ExportResult([path]);
    } catch (e) {
      await out.discard();
      if (e is ExportCancelledException || e is ExportFailure) rethrow;
      throw ExportFailure('The PDF could not be created.', e);
    } finally {
      await flattened?.dispose();
    }
  }

  static const editorUnavailable = "PDF export isn't available right now. Try PNG, JPG, TXT or DOCX instead.";
  static const flattenFailed =
      "Your annotations couldn't be added to the PDF. Turn off \"Include annotations\" to export without them.";

  static bool _isAll(List<int> pages, int count) {
    if (pages.length != count) return false;
    for (var i = 0; i < count; i++) {
      if (pages[i] != i + 1) return false;
    }
    return true;
  }
}
