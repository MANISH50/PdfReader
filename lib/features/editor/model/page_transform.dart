import 'package:material_ui/material_ui.dart';

/// Builds the PDF-point → widget-local transform for a page overlay.
///
/// * [pageSize]: UNROTATED page size in PDF points (for a pdfrx page with an
///   odd quarter-turn rotation that is `Size(page.height, page.width)`).
/// * [quarterTurns]: clockwise display rotation (pdfrx `PdfPageRotation.index`).
/// * [viewSize]: the size of the rendered page widget in logical pixels.
///
/// PDF space is y-up with origin bottom-left; widget space is y-down.
Matrix4 pdfToViewMatrix({required Size pageSize, required int quarterTurns, required Size viewSize}) {
  final w = pageSize.width, h = pageSize.height;
  final q = quarterTurns & 3;
  final rotW = q.isOdd ? h : w, rotH = q.isOdd ? w : h;
  final sx = rotW == 0 ? 1.0 : viewSize.width / rotW;
  final sy = rotH == 0 ? 1.0 : viewSize.height / rotH;
  // (x, y) pdf  →  (u, v) = (x, h - y) unrotated y-down  →  rotate cw  →  scale.
  final flip = Matrix4.identity()
    ..setEntry(1, 1, -1)
    ..setEntry(1, 3, h);
  final Matrix4 rot;
  switch (q) {
    case 1: // (u,v) -> (h - v, u)
      rot = Matrix4.zero()
        ..setEntry(0, 1, -1)
        ..setEntry(0, 3, h)
        ..setEntry(1, 0, 1)
        ..setEntry(2, 2, 1)
        ..setEntry(3, 3, 1);
    case 2: // (u,v) -> (w - u, h - v)
      rot = Matrix4.identity()
        ..setEntry(0, 0, -1)
        ..setEntry(0, 3, w)
        ..setEntry(1, 1, -1)
        ..setEntry(1, 3, h);
    case 3: // (u,v) -> (v, w - u)
      rot = Matrix4.zero()
        ..setEntry(0, 1, 1)
        ..setEntry(1, 0, -1)
        ..setEntry(1, 3, w)
        ..setEntry(2, 2, 1)
        ..setEntry(3, 3, 1);
    default:
      rot = Matrix4.identity();
  }
  return Matrix4.diagonal3Values(sx, sy, 1)
    ..multiply(rot)
    ..multiply(flip);
}

Offset transformPoint(Matrix4 m, Offset p) => MatrixUtils.transformPoint(m, p);

/// Average linear scale (view px per PDF pt) of [m].
double matrixScale(Matrix4 m) {
  final o = transformPoint(m, Offset.zero);
  final x = transformPoint(m, const Offset(1, 0)) - o;
  final y = transformPoint(m, const Offset(0, 1)) - o;
  return (x.distance + y.distance) / 2;
}

/// Builds the affine matrix of an arbitrary PDF → local point mapper (such
/// as the viewer's `ViewerPageInfo.pdfToLocal`) by sampling three points.
Matrix4 matrixFromPointMapper(Offset Function(Offset pdf) map) {
  final o = map(Offset.zero);
  final x = map(const Offset(1, 0)) - o;
  final y = map(const Offset(0, 1)) - o;
  return Matrix4.identity()
    ..setEntry(0, 0, x.dx)
    ..setEntry(1, 0, x.dy)
    ..setEntry(0, 1, y.dx)
    ..setEntry(1, 1, y.dy)
    ..setEntry(0, 3, o.dx)
    ..setEntry(1, 3, o.dy);
}
