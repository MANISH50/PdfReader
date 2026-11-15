import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:pdfium_dart/pdfium_dart.dart'
    show
        FPDF_DOCUMENT,
        FPDF_FONT,
        FPDF_PAGE,
        FPDF_PAGEOBJECT,
        FPDF_ANNOT_TEXT,
        FPDFANNOT_COLORTYPE,
        FPDFBitmap_BGRA,
        FPDF_FILLMODE_NONE,
        FPDF_FILLMODE_WINDING,
        FPDF_LINECAP_ROUND,
        FPDF_LINEJOIN_ROUND,
        PDFium;
import 'package:pdfrx/pdfrx.dart';

import '../../../core/models/annotation.dart';
import '../model/annotation_ops.dart';
import '../model/text_layout.dart';
import 'pdfium_native.dart';

/// Loads signature PNG bytes by id (null when missing).
typedef SignatureLoader = Future<Uint8List?> Function(String signatureId);

/// A straight-alpha BGRA raster prepared before the native phase.
class _Raster {
  _Raster(this.width, this.height, this.bgra);
  final int width, height;
  final Uint8List bgra;
}

/// Burns annotations into PDF page content with raw PDFium:
///
/// * highlight / underline / strike-out, ink, shapes → vector paths
///   (highlights use a 40 % fill with the Multiply blend mode);
/// * text boxes → real text objects in the standard Helvetica font (text a
///   standard font cannot encode, e.g. CJK, is rasterised at 4x instead);
/// * signatures → image objects with a soft mask (transparency kept);
/// * sticky notes → real `/Text` annotations (with `/Contents`) so the note
///   stays readable and editable in other PDF apps.
///
/// Output is a full rewrite of a copy; the source is never modified.
class Flattener {
  Flattener({this.loadSignature, this.maxImageSide = 4096});
  final SignatureLoader? loadSignature;
  final int maxImageSide;

  Future<Uint8List> flatten(PdfDocument source, List<Annotation> annotations) async {
    final bytes = await source.encodePdf(removeSecurity: true);
    final pageCount = source.pages.length;
    final byPage = <int, List<Annotation>>{};
    for (final a in annotations) {
      if (a.page < 1 || a.page > pageCount) continue;
      (byPage[a.page] ??= []).add(a);
    }
    if (byPage.isEmpty) return bytes;

    // Async preparation (decoding / rasterising) outside the PDFium lock.
    final rasters = <String, _Raster>{};
    for (final a in byPage.values.expand((l) => l)) {
      try {
        if (a is SignatureAnnotation && loadSignature != null) {
          final png = await loadSignature!(a.signatureId);
          final r = png == null ? null : _decodePng(png);
          if (r != null) rasters[a.id] = r;
        } else if (a is TextBoxAnnotation && !isWinAnsiEncodable(a.text)) {
          rasters[a.id] = await _rasterizeText(a);
        }
      } catch (_) {
        // Skip unreadable assets rather than failing the whole save.
      }
    }

    return NativePdf.edit(bytes, (byPage: byPage, rasters: rasters), _flattenTask);
  }

  /// Runs on the PDFium worker isolate.
  static void _flattenTask(
      FPDF_DOCUMENT doc, ({Map<int, List<Annotation>> byPage, Map<String, _Raster> rasters}) m) {
    final p = NativePdf.pdfium;
    final arena = Arena();
    final font = p.FPDFText_LoadStandardFont(doc, 'Helvetica'.toNativeUtf8(allocator: arena).cast());
    try {
      for (final entry in m.byPage.entries) {
        final page = p.FPDF_LoadPage(doc, entry.key - 1);
        if (page == nullptr) continue;
        try {
          final origin = NativePdf.withRect((r) {
            p.FPDF_GetPageBoundingBox(page, r);
            return Offset(r.ref.left, r.ref.bottom);
          });
          final w = _PageWriter(p, doc, page, origin, font, arena);
          for (final a in entry.value) {
            w.write(a, m.rasters[a.id]);
          }
          p.FPDFPage_GenerateContent(page);
        } finally {
          p.FPDF_ClosePage(page);
        }
      }
    } finally {
      if (font != nullptr) p.FPDFFont_Close(font);
      arena.releaseAll();
    }
  }

  _Raster? _decodePng(Uint8List png) {
    var image = img.decodePng(png);
    if (image == null) return null;
    final longest = math.max(image.width, image.height);
    if (longest > maxImageSide) {
      final s = maxImageSide / longest;
      image = img.copyResize(image,
          width: math.max(1, (image.width * s).round()), height: math.max(1, (image.height * s).round()));
    }
    final rgba = image.convert(numChannels: 4, format: img.Format.uint8);
    return _Raster(rgba.width, rgba.height, rgba.getBytes(order: img.ChannelOrder.bgra));
  }

  Future<_Raster> _rasterizeText(TextBoxAnnotation a) async {
    final r = normalizeRect(a.bounds);
    const scale = 4.0;
    final w = math.max(1, (r.width * scale).ceil()), h = math.max(1, (r.height * scale).ceil());
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(scale);
    final tp = TextPainter(
      text: TextSpan(text: a.text, style: TextStyle(color: a.color, fontSize: a.fontSize, height: kTextBoxLineHeight)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, r.width - 2 * kTextBoxPadding));
    tp.paint(canvas, const Offset(kTextBoxPadding, kTextBoxPadding));
    tp.dispose();
    final pic = rec.endRecording();
    final image = await pic.toImage(w, h);
    pic.dispose();
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
      for (var i = 0; i < data.length; i += 4) {
        final t = data[i];
        data[i] = data[i + 2];
        data[i + 2] = t;
      }
      return _Raster(w, h, data);
    } finally {
      image.dispose();
    }
  }
}

int _c(double v) => (v * 255).round().clamp(0, 255);

class _PageWriter {
  _PageWriter(this.p, this.doc, this.page, this.o, this.font, this._a);
  final PDFium p;
  final FPDF_DOCUMENT doc;
  final FPDF_PAGE page;
  final Offset o; // page box origin in user space
  final FPDF_FONT font;

  Offset _pt(Offset q) => q + o;

  void write(Annotation a, _Raster? raster) {
    switch (a) {
      case TextMarkupAnnotation(:final kind, :final rects, :final color):
        for (final raw in rects) {
          final r = normalizeRect(raw);
          if (r.isEmpty) continue;
          final t = math.max(0.75, r.height * 0.07);
          final Rect box = switch (kind) {
            MarkupKind.highlight => r,
            MarkupKind.underline => Rect.fromLTWH(r.left, r.top, r.width, t),
            MarkupKind.strikeout => Rect.fromLTWH(r.left, r.center.dy - t / 2, r.width, t),
          };
          final obj = _rectPath(box);
          _fill(obj, color, alpha: kind == MarkupKind.highlight ? 0.4 : color.a);
          if (kind == MarkupKind.highlight) p.FPDFPageObj_SetBlendMode(obj, _str('Multiply'));
          p.FPDFPath_SetDrawMode(obj, FPDF_FILLMODE_WINDING, 0);
          _insert(obj);
        }
      case NoteAnnotation(:final anchor, :final text, :final color):
        final annot = p.FPDFPage_CreateAnnot(page, FPDF_ANNOT_TEXT);
        if (annot == nullptr) return;
        try {
          NativePdf.withRect((r) {
            final a0 = _pt(anchor);
            r.ref
              ..left = a0.dx
              ..top = a0.dy
              ..right = a0.dx + kNoteIconSize
              ..bottom = a0.dy - kNoteIconSize;
            p.FPDFAnnot_SetRect(annot, r);
          });
          final w = NativePdf.wide(text);
          try {
            p.FPDFAnnot_SetStringValue(annot, _str('Contents'), w);
          } finally {
            calloc.free(w);
          }
          p.FPDFAnnot_SetColor(annot, FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color, _c(color.r), _c(color.g),
              _c(color.b), 255);
        } finally {
          p.FPDFPage_CloseAnnot(annot);
        }
      case InkAnnotation(:final strokes, :final strokeWidth, :final color):
        for (final s in strokes) {
          if (s.isEmpty) continue;
          final segs = smoothStroke(s);
          final start = _pt((segs.first as MoveSeg).p);
          final obj = p.FPDFPageObj_CreateNewPath(start.dx, start.dy);
          var cur = (segs.first as MoveSeg).p;
          for (final seg in segs.skip(1)) {
            switch (seg) {
              case LineSeg(p: final end):
                final q = _pt(end);
                p.FPDFPath_LineTo(obj, q.dx, q.dy);
                cur = end;
              case QuadSeg(:final c, p: final end):
                final c1 = _pt(cur + (c - cur) * (2 / 3));
                final c2 = _pt(end + (c - end) * (2 / 3));
                final e = _pt(end);
                p.FPDFPath_BezierTo(obj, c1.dx, c1.dy, c2.dx, c2.dy, e.dx, e.dy);
                cur = end;
              case MoveSeg():
                break;
            }
          }
          _stroke(obj, color, strokeWidth);
          _insert(obj);
        }
      case ShapeAnnotation(:final shape, :final bounds, :final strokeWidth, :final color):
        switch (shape) {
          case ShapeKind.rectangle:
            final obj = _rectPath(normalizeRect(bounds));
            _stroke(obj, color, strokeWidth);
            _insert(obj);
          case ShapeKind.ellipse:
            final obj = _ellipsePath(normalizeRect(bounds));
            _stroke(obj, color, strokeWidth);
            _insert(obj);
          case ShapeKind.line:
          case ShapeKind.arrow:
            final from = Offset(bounds.left, bounds.top), to = Offset(bounds.right, bounds.bottom);
            final a0 = _pt(from), b0 = _pt(to);
            final obj = p.FPDFPageObj_CreateNewPath(a0.dx, a0.dy);
            p.FPDFPath_LineTo(obj, b0.dx, b0.dy);
            if (shape == ShapeKind.arrow) {
              final (w1, w2) = arrowHead(from, to, strokeWidth);
              final q1 = _pt(w1), q2 = _pt(w2);
              p.FPDFPath_MoveTo(obj, q1.dx, q1.dy);
              p.FPDFPath_LineTo(obj, b0.dx, b0.dy);
              p.FPDFPath_LineTo(obj, q2.dx, q2.dy);
            }
            _stroke(obj, color, strokeWidth);
            _insert(obj);
        }
      case TextBoxAnnotation(:final bounds, :final text, :final fontSize, :final color):
        final r = normalizeRect(bounds);
        if (raster != null) {
          _image(raster, r);
          return;
        }
        if (font == nullptr) return;
        final lines = wrapText(text, fontSize, math.max(1, r.width - 2 * kTextBoxPadding));
        var baseline = r.bottom - kTextBoxPadding - fontSize * 0.8;
        for (final line in lines) {
          if (baseline < r.top - fontSize * 0.2) break;
          if (line.isNotEmpty) {
            final obj = p.FPDFPageObj_CreateTextObj(doc, font, fontSize);
            if (obj == nullptr) return;
            final w = NativePdf.wide(line);
            try {
              p.FPDFText_SetText(obj, w);
            } finally {
              calloc.free(w);
            }
            _fill(obj, color, alpha: color.a);
            final q = _pt(Offset(r.left + kTextBoxPadding, baseline));
            p.FPDFPageObj_Transform(obj, 1, 0, 0, 1, q.dx, q.dy);
            _insert(obj);
          }
          baseline -= fontSize * kTextBoxLineHeight;
        }
      case SignatureAnnotation(:final bounds):
        if (raster != null) _image(raster, normalizeRect(bounds));
    }
  }

  FPDF_PAGEOBJECT _rectPath(Rect r) {
    final a = _pt(r.topLeft);
    final obj = p.FPDFPageObj_CreateNewPath(a.dx, a.dy);
    for (final c in [r.topRight, r.bottomRight, r.bottomLeft]) {
      final q = _pt(c);
      p.FPDFPath_LineTo(obj, q.dx, q.dy);
    }
    p.FPDFPath_Close(obj);
    return obj;
  }

  FPDF_PAGEOBJECT _ellipsePath(Rect r) {
    const k = 0.5522847498;
    final cx = r.center.dx, cy = r.center.dy, rx = r.width / 2, ry = r.height / 2;
    Offset q(double x, double y) => _pt(Offset(x, y));
    final s = q(cx + rx, cy);
    final obj = p.FPDFPageObj_CreateNewPath(s.dx, s.dy);
    void bez(Offset c1, Offset c2, Offset e) => p.FPDFPath_BezierTo(obj, c1.dx, c1.dy, c2.dx, c2.dy, e.dx, e.dy);
    bez(q(cx + rx, cy + k * ry), q(cx + k * rx, cy + ry), q(cx, cy + ry));
    bez(q(cx - k * rx, cy + ry), q(cx - rx, cy + k * ry), q(cx - rx, cy));
    bez(q(cx - rx, cy - k * ry), q(cx - k * rx, cy - ry), q(cx, cy - ry));
    bez(q(cx + k * rx, cy - ry), q(cx + rx, cy - k * ry), q(cx + rx, cy));
    p.FPDFPath_Close(obj);
    return obj;
  }

  void _stroke(FPDF_PAGEOBJECT obj, Color c, double width) {
    p.FPDFPageObj_SetStrokeColor(obj, _c(c.r), _c(c.g), _c(c.b), _c(c.a));
    p.FPDFPageObj_SetStrokeWidth(obj, width);
    p.FPDFPageObj_SetLineCap(obj, FPDF_LINECAP_ROUND);
    p.FPDFPageObj_SetLineJoin(obj, FPDF_LINEJOIN_ROUND);
    p.FPDFPath_SetDrawMode(obj, FPDF_FILLMODE_NONE, 1);
  }

  void _fill(FPDF_PAGEOBJECT obj, Color c, {required double alpha}) =>
      p.FPDFPageObj_SetFillColor(obj, _c(c.r), _c(c.g), _c(c.b), _c(alpha));

  void _image(_Raster r, Rect box) {
    final obj = p.FPDFPageObj_NewImageObj(doc);
    if (obj == nullptr) return;
    final buf = malloc<Uint8>(r.bgra.length);
    try {
      buf.asTypedList(r.bgra.length).setAll(0, r.bgra);
      final bmp = p.FPDFBitmap_CreateEx(r.width, r.height, FPDFBitmap_BGRA, buf.cast(), r.width * 4);
      if (bmp == nullptr) {
        p.FPDFPageObj_Destroy(obj);
        return;
      }
      try {
        if (p.FPDFImageObj_SetBitmap(nullptr, 0, obj, bmp) == 0) {
          p.FPDFPageObj_Destroy(obj);
          return;
        }
      } finally {
        p.FPDFBitmap_Destroy(bmp);
      }
    } finally {
      malloc.free(buf);
    }
    final q = _pt(box.topLeft);
    p.FPDFImageObj_SetMatrix(obj, box.width, 0, 0, box.height, q.dx, q.dy);
    _insert(obj);
  }

  void _insert(FPDF_PAGEOBJECT obj) {
    if (obj != nullptr) p.FPDFPage_InsertObject(page, obj);
  }

  final Arena _a;
  Pointer<Char> _str(String s) => s.toNativeUtf8(allocator: _a).cast();
}
