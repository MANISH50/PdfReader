import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' show FPDF_DOCUMENT;
import 'package:pdfrx/pdfrx.dart';

import '../../../core/models/annotation.dart';
import '../../../core/pdf/page_editor.dart';
import '../../../core/security/limits.dart';
import 'flattener.dart';
import 'pdfium_native.dart';

/// One output page: page [pageNumber] (1-based) of [document], turned
/// clockwise by [quarterTurns] on top of its existing rotation.
class PageSource {
  const PageSource(this.document, this.pageNumber, {this.quarterTurns = 0});
  final PdfDocument document;
  final int pageNumber;
  final int quarterTurns;
}

class PageEditException implements Exception {
  const PageEditException(this.message);
  final String message;
  @override
  String toString() => 'PageEditException: $message';
}

/// [PageEditor] on top of pdfrx's page assembly (`pages` setter, `rotatedBy`,
/// `assemble`, `encodePdf`) and raw PDFium for flattening.
///
/// Source documents are never modified:
/// * If the output keeps every page of a single document (reorder / rotate /
///   duplicate), a private copy is rearranged with raw PDFium, which keeps
///   document-level data (form fields, outline, metadata).
/// * Otherwise (delete / extract / split / merge) the output is built in a
///   brand-new document that only imports the used pages, so content of
///   removed pages cannot leak into the file. Interactive form fields and
///   the outline are not carried over in that case (pages still render
///   their appearance).
///
/// Encrypted inputs produce unencrypted outputs (they are written to
/// app-private storage).
///
/// [PageSpec.rotationDegrees] is RELATIVE: it is added to the page's
/// current rotation.
class PdfrxPageEditor implements PageEditor {
  PdfrxPageEditor({SignatureLoader? loadSignature}) : _flattener = Flattener(loadSignature: loadSignature);

  final Flattener _flattener;

  static PdfPageRotation _turns(int quarterTurns) => PdfPageRotation.values[quarterTurns & 3];

  static int degreesToQuarterTurns(int degrees) {
    if (degrees % 90 != 0) throw PageEditException('Rotation must be a multiple of 90° (got $degrees)');
    return (degrees ~/ 90) & 3;
  }

  /// Builds a PDF from [pages] (which may come from several documents).
  /// [base] decides which document's catalog is kept when all of its pages
  /// are present; defaults to the first page's document.
  Future<Uint8List> compose(List<PageSource> pages, {PdfDocument? base}) async {
    if (pages.isEmpty) throw const PageEditException('A PDF needs at least one page');
    if (pages.length > SecurityLimits.maxPages) throw const PageEditException('Too many pages');
    final docs = <PdfDocument>{};
    for (final s in pages) {
      if (s.pageNumber < 1 || s.pageNumber > s.document.pages.length) {
        throw PageEditException('Page ${s.pageNumber} does not exist');
      }
      docs.add(s.document);
    }
    if (docs.length > SecurityLimits.maxMergeInputs) throw const PageEditException('Too many documents');
    final b = base ?? pages.first.document;
    final keepsAll = docs.length == 1 &&
        docs.contains(b) &&
        {for (final s in pages) s.pageNumber}.length == b.pages.length;

    if (keepsAll) {
      // Rearrange a private copy natively (keeps catalog: forms, outline).
      // pdfrx 2.12.1's in-document reorder via the `pages` setter is not used:
      // its arranger maps renumbered same-document pages by their NEW number.
      final bytes = await b.encodePdf(removeSecurity: true);
      return NativePdf.edit(
          bytes, [for (final s in pages) (s.pageNumber - 1, s.quarterTurns & 3)], _rearrangeTask);
    }

    final out = await PdfDocument.createNew(sourceName: 'compose-new');
    try {
      out.pages = [
        for (final s in pages) s.document.pages[s.pageNumber - 1].rotatedBy(_turns(s.quarterTurns)),
      ];
      return await out.encodePdf();
    } finally {
      await out.dispose();
    }
  }

  /// Runs on the PDFium worker: reorders / duplicates / rotates pages so the
  /// document matches [order] (original 0-based index, extra quarter turns).
  /// Every original page appears at least once.
  static void _rearrangeTask(FPDF_DOCUMENT doc, List<(int, int)> order) {
    final p = NativePdf.pdfium;
    final n = p.FPDF_GetPageCount(doc);
    final seen = <int>{};
    final target = <int>[]; // physical ids
    final physical = List<int>.generate(n, (i) => i);
    using((arena) {
      final idx = arena<Int>();
      for (final (orig, _) in order) {
        if (orig < 0 || orig >= n) throw const PageEditException('Page out of range');
        if (seen.add(orig)) {
          target.add(orig);
        } else {
          idx.value = orig;
          if (p.FPDF_ImportPagesByIndex(doc, doc, idx, 1, physical.length) == 0) {
            throw const PageEditException('Could not duplicate page');
          }
          final id = physical.length;
          physical.add(id);
          target.add(id);
        }
      }
      // physical[k] = id of the page now at index k; ids < n are originals.
      for (var j = 0; j < target.length; j++) {
        final pos = physical.indexOf(target[j]);
        if (pos == j) continue;
        idx.value = pos;
        if (p.FPDF_MovePages(doc, idx, 1, j) == 0) throw const PageEditException('Could not move page');
        physical.insert(j, physical.removeAt(pos));
      }
    });
    for (var j = 0; j < order.length; j++) {
      final q = order[j].$2;
      if (q == 0) continue;
      final page = p.FPDF_LoadPage(doc, j);
      if (page == nullptr) continue;
      final cur = p.FPDFPage_GetRotation(page);
      p.FPDFPage_SetRotation(page, ((cur < 0 ? 0 : cur) + q) & 3);
      p.FPDF_ClosePage(page);
    }
  }

  @override
  Future<Uint8List> rebuild(PdfDocument source, List<PageSpec> pages) => compose(
        [
          for (final s in pages)
            PageSource(source, s.pageNumber, quarterTurns: degreesToQuarterTurns(s.rotationDegrees)),
        ],
        base: source,
      );

  @override
  Future<Uint8List> merge(List<PdfDocument> docs) {
    if (docs.isEmpty) throw const PageEditException('Nothing to merge');
    return compose([
      for (final d in docs)
        for (var i = 1; i <= d.pages.length; i++) PageSource(d, i),
    ], base: docs.first);
  }

  @override
  Future<List<Uint8List>> split(PdfDocument source, List<List<int>> ranges) async {
    if (ranges.isEmpty) throw const PageEditException('No ranges');
    return [
      for (final r in ranges) await compose([for (final n in r) PageSource(source, n)], base: source),
    ];
  }

  @override
  Future<Uint8List> flatten(PdfDocument source, List<Annotation> annotations) =>
      _flattener.flatten(source, annotations);
}
