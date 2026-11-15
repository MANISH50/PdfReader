import 'dart:ffi' as ffi;

import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import 'layout.dart';

/// Reads per-character font size / weight / italic for one page. Returns
/// null when unavailable; callers must work without it.
typedef CharStyleProbe = Future<List<CharStyle?>?> Function(PdfDocument doc, int pageNumber, String expectedText);

/// Best-effort probe via PDFium's text API (FPDFText_GetFontSize,
/// FPDFText_GetFontWeight, font descriptor flags), run through pdfrx's
/// `useNativeDocumentHandle` so the pdfrx worker is suspended meanwhile.
///
/// The result is only used when the probed characters match the text pdfrx
/// returned for the page (same order and count); otherwise null.
Future<List<CharStyle?>?> pdfiumCharStyleProbe(PdfDocument doc, int pageNumber, String expectedText) async {
  try {
    return await doc.useNativeDocumentHandle((handle) {
      final p = _pdfium ??= pdfium.getPdfium(modulePath: Pdfrx.pdfiumModulePath);
      final page = p.FPDF_LoadPage(pdfium.FPDF_DOCUMENT.fromAddress(handle), pageNumber - 1);
      if (page == ffi.nullptr) return null;
      final textPage = p.FPDFText_LoadPage(page);
      try {
        if (textPage == ffi.nullptr) return null;
        final count = p.FPDFText_CountChars(textPage);
        if (count != expectedText.length || count > _maxChars) return null;
        final fontCache = <int, (bool, bool)>{};
        final out = List<CharStyle?>.filled(count, null);
        for (var i = 0; i < count; i++) {
          if (p.FPDFText_GetUnicode(textPage, i) != expectedText.codeUnitAt(i)) return null;
          final obj = p.FPDFText_GetTextObject(textPage, i);
          if (obj == ffi.nullptr) continue; // generated space / line break
          final font = p.FPDFTextObj_GetFont(obj);
          final (fontBold, italic) = font == ffi.nullptr
              ? (false, false)
              : fontCache.putIfAbsent(font.address, () {
                  final flags = p.FPDFFont_GetFlags(font);
                  // PDF 1.7 §5.7.1 font descriptor flags: Italic = bit 7, ForceBold = bit 19.
                  return (flags >= 0 && flags & (1 << 18) != 0, flags >= 0 && flags & (1 << 6) != 0);
                });
          final weight = p.FPDFText_GetFontWeight(textPage, i);
          final size = p.FPDFText_GetFontSize(textPage, i);
          out[i] = CharStyle(
            fontSize: size.isFinite && size > 0 ? size : null,
            bold: fontBold || weight >= 600,
            italic: italic,
          );
        }
        return out;
      } finally {
        if (textPage != ffi.nullptr) p.FPDFText_ClosePage(textPage);
        p.FPDF_ClosePage(page);
      }
    });
  } catch (_) {
    return null;
  }
}

pdfium.PDFium? _pdfium;
const int _maxChars = 200000;
