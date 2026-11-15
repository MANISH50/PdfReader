import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import 'layout.dart';

/// Engine facts about one page that pdfrx's public API does not expose.
class PageProbe {
  const PageProbe({this.styles, required this.hasGraphics});

  /// Per-character styles aligned with the page's raw text, or null when
  /// unavailable (mismatch, too many characters, engine error).
  final List<CharStyle?>? styles;

  /// True when the page has image, shading or form XObjects, or a fair
  /// number of vector paths (i.e. content a page image would preserve).
  final bool hasGraphics;
}

/// Probes one page; returns null when the engine cannot be queried.
typedef PageProber = Future<PageProbe?> Function(PdfDocument doc, int pageNumber, String expectedText);

/// Above this many characters per page the style probe is skipped (unstyled
/// fallback) to bound time spent on pdfrx's worker.
const int maxStyledCharsPerPage = 20000;

/// Max page objects inspected for [PageProbe.hasGraphics].
const int _maxObjects = 10000;

/// Best-effort probe via PDFium's text and page-object APIs. Raw PDFium calls
/// run on pdfrx's own worker isolate ([PdfrxEntryFunctions.compute]), as
/// pdfrx's engine does, never on the UI isolate.
///
/// Styles are only returned when the probed characters match the text pdfrx
/// returned for the page (same order and count).
Future<PageProbe?> pdfiumPageProbe(PdfDocument doc, int pageNumber, String expectedText) async {
  try {
    final handle = await doc.useNativeDocumentHandle((h) => h);
    final r = await PdfrxEntryFunctions.instance.compute(_probeOnWorker, (
      doc: handle,
      pageIndex: pageNumber - 1,
      modulePath: Pdfrx.pdfiumModulePath,
      text: expectedText.length <= maxStyledCharsPerPage ? expectedText : null,
    ));
    if (r == null) return null;
    List<CharStyle?>? styles;
    final sizes = r.sizes, flags = r.flags;
    if (sizes != null && flags != null) {
      styles = List<CharStyle?>.generate(sizes.length, (i) {
        final f = flags[i];
        if (f & _present == 0) return null;
        final s = sizes[i];
        return CharStyle(fontSize: s.isFinite && s > 0 ? s : null, bold: f & _bold != 0, italic: f & _italic != 0);
      });
    }
    return PageProbe(styles: styles, hasGraphics: r.hasGraphics);
  } catch (_) {
    return null;
  }
}

const int _present = 1, _bold = 2, _italic = 4;

pdfium.PDFium? _pdfium;

typedef _ProbeArgs = ({int doc, int pageIndex, String? modulePath, String? text});
typedef _ProbeResult = ({Float64List? sizes, Uint8List? flags, bool hasGraphics});

/// Runs on pdfrx's worker isolate.
_ProbeResult? _probeOnWorker(_ProbeArgs a) {
  final p = _pdfium ??= pdfium.getPdfium(modulePath: a.modulePath);
  final page = p.FPDF_LoadPage(pdfium.FPDF_DOCUMENT.fromAddress(a.doc), a.pageIndex);
  if (page == ffi.nullptr) return null;
  try {
    // Page objects: image=3, shading=4, form=5, path=2 (fpdf_edit.h).
    var paths = 0;
    var graphics = false;
    final count = p.FPDFPage_CountObjects(page);
    for (var i = 0; i < count && i < _maxObjects && !graphics; i++) {
      final type = p.FPDFPageObj_GetType(p.FPDFPage_GetObject(page, i));
      if (type >= 3 && type <= 5) graphics = true;
      if (type == 2 && ++paths >= 20) graphics = true;
    }
    final text = a.text;
    if (text == null) return (sizes: null, flags: null, hasGraphics: graphics);
    final textPage = p.FPDFText_LoadPage(page);
    if (textPage == ffi.nullptr) return (sizes: null, flags: null, hasGraphics: graphics);
    try {
      final n = p.FPDFText_CountChars(textPage);
      if (n != text.length) return (sizes: null, flags: null, hasGraphics: graphics);
      final sizes = Float64List(n);
      final flags = Uint8List(n);
      final fontCache = <int, int>{};
      for (var i = 0; i < n; i++) {
        if (p.FPDFText_GetUnicode(textPage, i) != text.codeUnitAt(i)) {
          return (sizes: null, flags: null, hasGraphics: graphics);
        }
        final obj = p.FPDFText_GetTextObject(textPage, i);
        if (obj == ffi.nullptr) continue; // generated space / line break
        final font = p.FPDFTextObj_GetFont(obj);
        final fontBits = font == ffi.nullptr
            ? 0
            : fontCache.putIfAbsent(font.address, () {
                final f = p.FPDFFont_GetFlags(font);
                // PDF 1.7 §5.7.1 font descriptor flags: Italic = bit 7, ForceBold = bit 19.
                if (f < 0) return 0;
                return (f & (1 << 18) != 0 ? _bold : 0) | (f & (1 << 6) != 0 ? _italic : 0);
              });
        final weight = p.FPDFText_GetFontWeight(textPage, i);
        sizes[i] = p.FPDFText_GetFontSize(textPage, i);
        flags[i] = _present | fontBits | (weight >= 600 ? _bold : 0);
      }
      return (sizes: sizes, flags: flags, hasGraphics: graphics);
    } finally {
      p.FPDFText_ClosePage(textPage);
    }
  } finally {
    p.FPDF_ClosePage(page);
  }
}
