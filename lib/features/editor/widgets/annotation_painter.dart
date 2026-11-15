import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/models/annotation.dart';
import '../model/annotation_ops.dart';
import '../model/page_transform.dart';
import '../model/text_layout.dart';
import '../signature/signature_store.dart';

/// Paints annotations in PDF space (the canvas is transformed by [matrix]).
class AnnotationPainter extends CustomPainter {
  AnnotationPainter({
    required this.annotations,
    required this.matrix,
    this.images,
    this.selectedId,
    this.preview,
    this.selectionColor = const Color(0xFF3B5BDB),
    super.repaint,
  });

  final List<Annotation> annotations;
  final Matrix4 matrix;
  final SignatureImageCache? images;
  final String? selectedId;

  /// An in-progress annotation (stroke being drawn, shape being dragged, or a
  /// selected annotation being moved) drawn on top.
  final Annotation? preview;
  final Color selectionColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.transform(matrix.storage);
    final scale = matrixScale(matrix);
    for (final a in annotations) {
      if (preview != null && preview!.id == a.id) continue;
      paintAnnotation(canvas, a, images);
    }
    if (preview != null) paintAnnotation(canvas, preview!, images);
    final sel = preview?.id == selectedId && preview != null
        ? preview
        : annotations.where((a) => a.id == selectedId).firstOrNull;
    if (sel != null) _paintSelection(canvas, sel, scale);
    canvas.restore();
  }

  void _paintSelection(Canvas canvas, Annotation a, double scale) {
    final px = 1 / (scale == 0 ? 1 : scale);
    final r = annotationBounds(a).inflate(3 * px);
    canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * px
          ..color = selectionColor);
    if (a is NoteAnnotation || a is TextMarkupAnnotation) return;
    final hp = Paint()..color = selectionColor;
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 6 * px, Paint()..color = Colors.white);
      canvas.drawCircle(c, 4.5 * px, hp);
    }
  }

  @override
  bool shouldRepaint(AnnotationPainter old) =>
      old.annotations != annotations ||
      old.matrix != matrix ||
      old.selectedId != selectedId ||
      old.preview != preview ||
      old.images != images;
}

/// Paints one annotation onto a canvas already in PDF space (y-up).
void paintAnnotation(Canvas canvas, Annotation a, SignatureImageCache? images) {
  switch (a) {
    case TextMarkupAnnotation(:final kind, :final rects, :final color):
      for (final raw in rects) {
        final r = normalizeRect(raw);
        switch (kind) {
          case MarkupKind.highlight:
            canvas.drawRect(
                r,
                Paint()
                  ..color = color.withValues(alpha: 0.4)
                  ..blendMode = BlendMode.multiply);
          case MarkupKind.underline:
            final t = math.max(0.75, r.height * 0.07);
            canvas.drawRect(Rect.fromLTWH(r.left, r.top, r.width, t), Paint()..color = color);
          case MarkupKind.strikeout:
            final t = math.max(0.75, r.height * 0.07);
            canvas.drawRect(Rect.fromLTWH(r.left, r.center.dy - t / 2, r.width, t), Paint()..color = color);
        }
      }
    case NoteAnnotation(:final anchor, :final color):
      paintNoteIcon(canvas, anchor, color);
    case InkAnnotation(:final strokes, :final strokeWidth, :final color):
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color;
      for (final s in strokes) {
        canvas.drawPath(strokePath(s), paint);
      }
    case ShapeAnnotation(:final shape, :final bounds, :final strokeWidth, :final color):
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color;
      switch (shape) {
        case ShapeKind.rectangle:
          canvas.drawRect(normalizeRect(bounds), paint);
        case ShapeKind.ellipse:
          canvas.drawOval(normalizeRect(bounds), paint);
        case ShapeKind.line:
        case ShapeKind.arrow:
          final from = Offset(bounds.left, bounds.top), to = Offset(bounds.right, bounds.bottom);
          canvas.drawLine(from, to, paint);
          if (shape == ShapeKind.arrow) {
            final (w1, w2) = arrowHead(from, to, strokeWidth);
            canvas.drawPath(Path()
              ..moveTo(w1.dx, w1.dy)
              ..lineTo(to.dx, to.dy)
              ..lineTo(w2.dx, w2.dy), paint);
          }
      }
    case TextBoxAnnotation(:final bounds, :final text, :final fontSize, :final color):
      final r = normalizeRect(bounds);
      canvas.save();
      canvas.clipRect(r.inflate(1));
      // Flip to y-down local space anchored at the visual top-left.
      canvas.translate(r.left, r.bottom);
      canvas.scale(1, -1);
      final lines = wrapText(text, fontSize, math.max(1, r.width - 2 * kTextBoxPadding));
      var y = kTextBoxPadding;
      for (final line in lines) {
        final tp = TextPainter(
          text: TextSpan(
              text: line,
              style: TextStyle(color: color, fontSize: fontSize, height: 1.0, fontFamily: 'Helvetica',
                  fontFamilyFallback: const ['Arial', 'Roboto', 'sans-serif'])),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        tp.paint(canvas, Offset(kTextBoxPadding, y));
        tp.dispose();
        y += fontSize * kTextBoxLineHeight;
      }
      canvas.restore();
    case SignatureAnnotation(:final bounds, :final signatureId):
      final r = normalizeRect(bounds);
      final img = images?.get(signatureId);
      if (img == null) {
        canvas.drawRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.75
              ..color = const Color(0x66000000));
        return;
      }
      canvas.save();
      canvas.translate(r.left, r.bottom);
      canvas.scale(1, -1);
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Rect.fromLTWH(0, 0, r.width, r.height), Paint()..filterQuality = FilterQuality.medium);
      canvas.restore();
  }
}

Path strokePath(List<Offset> pts) {
  final path = Path();
  for (final s in smoothStroke(pts)) {
    switch (s) {
      case MoveSeg(:final p):
        path.moveTo(p.dx, p.dy);
      case LineSeg(:final p):
        path.lineTo(p.dx, p.dy);
      case QuadSeg(:final c, :final p):
        path.quadraticBezierTo(c.dx, c.dy, p.dx, p.dy);
    }
  }
  return path;
}

/// Sticky-note icon: rounded square with a folded corner and text lines.
void paintNoteIcon(Canvas canvas, Offset anchor, Color color) {
  const s = kNoteIconSize;
  final r = Rect.fromLTWH(anchor.dx, anchor.dy - s, s, s);
  canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2.5)), Paint()..color = color);
  canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(2.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = const Color(0x99000000));
  final line = Paint()
    ..strokeWidth = 1.2
    ..color = const Color(0xAA000000);
  for (var i = 1; i <= 3; i++) {
    final y = anchor.dy - s * i / 4.2;
    canvas.drawLine(Offset(anchor.dx + 4, y), Offset(anchor.dx + s - 4, y), line);
  }
}
