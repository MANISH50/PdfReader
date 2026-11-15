import 'dart:math' as math;
import 'dart:ui';

import '../../../core/models/annotation.dart';

/// Geometry helpers for [Annotation]s.
///
/// Conventions (all in PDF points, origin bottom-left of the page's visible
/// box, unrotated page — the same space as pdfrx `PdfRect`):
/// * Rects are stored normalised (`left <= right`, `top <= bottom`
///   numerically). Because PDF space is y-up, `rect.top` is the visually
///   LOWER edge and `rect.bottom` the visually upper edge.
/// * Exception: [ShapeAnnotation] with [ShapeKind.line] / [ShapeKind.arrow]
///   keeps `bounds` unnormalised: the line goes from `(left, top)` to
///   `(right, bottom)` (the arrow head is at `(right, bottom)`).
/// * [NoteAnnotation.anchor] is the top-left corner of the note icon
///   (visually), i.e. the icon spans `x..x+[kNoteIconSize]`,
///   `y-[kNoteIconSize]..y`.
const double kNoteIconSize = 20;

final _rand = math.Random.secure();

/// Random, collision-resistant annotation / signature id (`[a-z0-9]`).
String newAnnotationId() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = List.generate(8, (_) => _rand.nextInt(36).toRadixString(36)).join();
  return '$t$r';
}

/// Converts a pdfrx-style rect (left, top=upper y, right, bottom=lower y) or
/// any 4 edges into the normalised storage rect.
Rect pdfRectFromEdges(double left, double top, double right, double bottom) =>
    Rect.fromLTRB(math.min(left, right), math.min(top, bottom), math.max(left, right), math.max(top, bottom));

Rect normalizeRect(Rect r) => pdfRectFromEdges(r.left, r.top, r.right, r.bottom);

/// Axis-aligned bounds of [a] in PDF space (normalised).
Rect annotationBounds(Annotation a) => switch (a) {
      TextMarkupAnnotation(:final rects) => rects.isEmpty
          ? Rect.zero
          : rects.skip(1).fold(normalizeRect(rects.first), (r, e) => r.expandToInclude(normalizeRect(e))),
      NoteAnnotation(:final anchor) =>
        Rect.fromLTRB(anchor.dx, anchor.dy - kNoteIconSize, anchor.dx + kNoteIconSize, anchor.dy),
      InkAnnotation(:final strokes, :final strokeWidth) => _pointsBounds(strokes.expand((s) => s))
          .inflate(strokeWidth / 2),
      ShapeAnnotation(:final bounds, :final strokeWidth) => normalizeRect(bounds).inflate(strokeWidth / 2),
      TextBoxAnnotation(:final bounds) => normalizeRect(bounds),
      SignatureAnnotation(:final bounds) => normalizeRect(bounds),
    };

Rect _pointsBounds(Iterable<Offset> pts) {
  double? l, t, r, b;
  for (final p in pts) {
    l = l == null ? p.dx : math.min(l, p.dx);
    r = r == null ? p.dx : math.max(r, p.dx);
    t = t == null ? p.dy : math.min(t, p.dy);
    b = b == null ? p.dy : math.max(b, p.dy);
  }
  return l == null ? Rect.zero : Rect.fromLTRB(l, t!, r!, b!);
}

Rect _mapRect(Rect r, Offset Function(Offset) f, {bool normalize = true}) {
  final a = f(Offset(r.left, r.top));
  final b = f(Offset(r.right, r.bottom));
  final out = Rect.fromLTRB(a.dx, a.dy, b.dx, b.dy);
  return normalize ? normalizeRect(out) : out;
}

/// Returns a copy of [a] with every point mapped through [f] (an affine map
/// such as a translation or a bounds-to-bounds scale).
Annotation mapAnnotation(Annotation a, Offset Function(Offset) f) => switch (a) {
      TextMarkupAnnotation() => TextMarkupAnnotation(
          id: a.id, page: a.page, color: a.color, createdAt: a.createdAt,
          kind: a.kind, text: a.text, rects: [for (final r in a.rects) _mapRect(r, f)]),
      NoteAnnotation() => NoteAnnotation(
          id: a.id, page: a.page, color: a.color, createdAt: a.createdAt, text: a.text, anchor: f(a.anchor)),
      InkAnnotation() => InkAnnotation(
          id: a.id, page: a.page, color: a.color, createdAt: a.createdAt, strokeWidth: a.strokeWidth,
          strokes: [for (final s in a.strokes) [for (final p in s) f(p)]]),
      ShapeAnnotation() => ShapeAnnotation(
          id: a.id, page: a.page, color: a.color, createdAt: a.createdAt, shape: a.shape,
          strokeWidth: a.strokeWidth,
          bounds: _mapRect(a.bounds, f, normalize: !isDirectionalShape(a.shape))),
      TextBoxAnnotation() => TextBoxAnnotation(
          id: a.id, page: a.page, color: a.color, createdAt: a.createdAt, text: a.text, fontSize: a.fontSize,
          bounds: _mapRect(a.bounds, f)),
      SignatureAnnotation() => SignatureAnnotation(
          id: a.id, page: a.page, color: a.color, createdAt: a.createdAt, signatureId: a.signatureId,
          bounds: _mapRect(a.bounds, f)),
    };

bool isDirectionalShape(ShapeKind k) => k == ShapeKind.line || k == ShapeKind.arrow;

Annotation translateAnnotation(Annotation a, Offset delta) => mapAnnotation(a, (p) => p + delta);

/// Scales [a] so that its [from] rect maps onto [to].
Annotation resizeAnnotation(Annotation a, Rect from, Rect to) {
  final sx = from.width == 0 ? 1.0 : to.width / from.width;
  final sy = from.height == 0 ? 1.0 : to.height / from.height;
  return mapAnnotation(a, (p) => Offset(to.left + (p.dx - from.left) * sx, to.top + (p.dy - from.top) * sy));
}

/// Returns a copy with a different colour (or the same instance for types
/// whose colour is meaningless).
Annotation recolorAnnotation(Annotation a, Color c) => switch (a) {
      TextMarkupAnnotation() => TextMarkupAnnotation(
          id: a.id, page: a.page, color: c, createdAt: a.createdAt, kind: a.kind, rects: a.rects, text: a.text),
      NoteAnnotation() =>
        NoteAnnotation(id: a.id, page: a.page, color: c, createdAt: a.createdAt, anchor: a.anchor, text: a.text),
      InkAnnotation() => InkAnnotation(
          id: a.id, page: a.page, color: c, createdAt: a.createdAt, strokes: a.strokes, strokeWidth: a.strokeWidth),
      ShapeAnnotation() => ShapeAnnotation(
          id: a.id, page: a.page, color: c, createdAt: a.createdAt, shape: a.shape, bounds: a.bounds,
          strokeWidth: a.strokeWidth),
      TextBoxAnnotation() => TextBoxAnnotation(
          id: a.id, page: a.page, color: c, createdAt: a.createdAt, bounds: a.bounds, text: a.text,
          fontSize: a.fontSize),
      SignatureAnnotation() => a,
    };

/// Returns a copy of a note / text box with new text; other types unchanged.
Annotation withText(Annotation a, String text) => switch (a) {
      NoteAnnotation() =>
        NoteAnnotation(id: a.id, page: a.page, color: a.color, createdAt: a.createdAt, anchor: a.anchor, text: text),
      TextBoxAnnotation() => TextBoxAnnotation(
          id: a.id, page: a.page, color: a.color, createdAt: a.createdAt, bounds: a.bounds, text: text,
          fontSize: a.fontSize),
      _ => a,
    };

double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// True if [p] (PDF space) hits [a] within [tolerance] points.
bool hitTestAnnotation(Annotation a, Offset p, double tolerance) {
  switch (a) {
    case InkAnnotation(:final strokes, :final strokeWidth):
      final tol = tolerance + strokeWidth / 2;
      for (final s in strokes) {
        if (s.length == 1 && (s.first - p).distance <= tol) return true;
        for (var i = 1; i < s.length; i++) {
          if (_distToSegment(p, s[i - 1], s[i]) <= tol) return true;
        }
      }
      return false;
    case ShapeAnnotation(:final shape, :final bounds, :final strokeWidth) when isDirectionalShape(shape):
      return _distToSegment(p, Offset(bounds.left, bounds.top), Offset(bounds.right, bounds.bottom)) <=
          tolerance + strokeWidth / 2;
    case TextMarkupAnnotation(:final rects):
      return rects.any((r) => normalizeRect(r).inflate(tolerance).contains(p));
    default:
      return annotationBounds(a).inflate(tolerance).contains(p);
  }
}

/// Topmost annotation hit at [p], or null.
Annotation? hitTestAll(Iterable<Annotation> list, Offset p, double tolerance) {
  Annotation? hit;
  for (final a in list) {
    if (hitTestAnnotation(a, p, tolerance)) hit = a;
  }
  return hit;
}

/// Drops points closer than [minDistance] to the previous kept point (keeps
/// the last point), reducing stroke size before storage.
List<Offset> simplifyStroke(List<Offset> pts, {double minDistance = 0.75}) {
  if (pts.length < 3) return List.of(pts);
  final out = <Offset>[pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    if ((pts[i] - out.last).distance >= minDistance) out.add(pts[i]);
  }
  out.add(pts.last);
  return out;
}

/// A smooth path segment: either a move, a line, or a quadratic curve.
/// Used by both the on-screen painter and the PDF flattener so they draw
/// the same curve: quadratic Béziers through stroke midpoints.
sealed class StrokeSeg {
  const StrokeSeg();
}

class MoveSeg extends StrokeSeg {
  const MoveSeg(this.p);
  final Offset p;
}

class LineSeg extends StrokeSeg {
  const LineSeg(this.p);
  final Offset p;
}

class QuadSeg extends StrokeSeg {
  const QuadSeg(this.c, this.p);
  final Offset c, p;
}

List<StrokeSeg> smoothStroke(List<Offset> pts) {
  if (pts.isEmpty) return const [];
  final out = <StrokeSeg>[MoveSeg(pts.first)];
  if (pts.length == 1) {
    out.add(LineSeg(pts.first + const Offset(0.01, 0)));
    return out;
  }
  if (pts.length == 2) {
    out.add(LineSeg(pts[1]));
    return out;
  }
  out.add(LineSeg((pts[0] + pts[1]) / 2));
  for (var i = 1; i < pts.length - 1; i++) {
    out.add(QuadSeg(pts[i], (pts[i] + pts[i + 1]) / 2));
  }
  out.add(LineSeg(pts.last));
  return out;
}

/// Arrow head wing points for a line from [from] to [to].
(Offset, Offset) arrowHead(Offset from, Offset to, double strokeWidth) {
  final d = to - from;
  final len = d.distance;
  if (len == 0) return (to, to);
  final size = math.max(8.0, strokeWidth * 4);
  final ux = d.dx / len, uy = d.dy / len;
  const ang = math.pi / 7;
  Offset wing(double s) {
    final c = math.cos(s * ang), sn = math.sin(s * ang);
    final rx = ux * c - uy * sn, ry = ux * sn + uy * c;
    return to - Offset(rx, ry) * size;
  }

  return (wing(1), wing(-1));
}
