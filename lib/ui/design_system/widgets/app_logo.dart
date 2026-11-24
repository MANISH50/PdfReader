import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// The PdfReader mark: a document sheet with a folded corner and a reading
/// lens. Geometry mirrors `assets/branding/icon.svg` and
/// `tool/branding/render_icon.py` (1024-unit canvas).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96, this.withBackground = true});
  final double size;

  /// Draw the rounded-square indigo tile behind the mark.
  final bool withBackground;

  @override
  Widget build(BuildContext context) => Semantics(
        image: true,
        label: 'PdfReader logo',
        child: CustomPaint(
          size: Size.square(size),
          painter: AppLogoPainter(withBackground: withBackground),
        ),
      );
}

class AppLogoPainter extends CustomPainter {
  const AppLogoPainter({this.withBackground = true});
  final bool withBackground;

  // Geometry in 1024 units.
  static const double l = 254, t = 182, r = 678, b = 786, corner = 44, fold = 132;
  static const Offset lensCenter = Offset(554, 626);
  static const double lensRadius = 112, lensStroke = 40;
  static const Offset handleStart = Offset(648, 720), handleEnd = Offset(744, 816);
  static const double handleStroke = 52, lineStroke = 34;
  static const List<(double, double, double)> lines = [
    (340, 334, 520),
    (420, 334, 598),
    (500, 334, 470),
  ];
  static const Color lineColor = Color(0xFFC5CEF2);
  static const Color foldColor = Color(0xFFDCE3FB);
  static const Color glass = Color(0xFFFFF4DE);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 1024;
    canvas.save();
    canvas.scale(k);
    if (withBackground) {
      const rect = Rect.fromLTWH(0, 0, 1024, 1024);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(230)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: Brand.gradientColors,
          ).createShader(rect),
      );
    }
    final sheet = Path()
      ..moveTo(l + corner, t)
      ..lineTo(r - fold, t)
      ..lineTo(r, t + fold)
      ..lineTo(r, b - corner)
      ..arcToPoint(const Offset(r - corner, b), radius: const Radius.circular(corner))
      ..lineTo(l + corner, b)
      ..arcToPoint(const Offset(l, b - corner), radius: const Radius.circular(corner))
      ..lineTo(l, t + corner)
      ..arcToPoint(const Offset(l + corner, t), radius: const Radius.circular(corner))
      ..close();
    canvas.drawPath(sheet, Paint()..color = Brand.paper);
    canvas.drawPath(
      Path()
        ..moveTo(r - fold, t)
        ..lineTo(r - fold, t + fold - 18)
        ..quadraticBezierTo(r - fold, t + fold, r - fold + 18, t + fold)
        ..lineTo(r, t + fold)
        ..close(),
      Paint()..color = foldColor,
    );
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = lineStroke
      ..strokeCap = StrokeCap.round;
    for (final (y, x0, x1) in lines) {
      canvas.drawLine(Offset(x0, y), Offset(x1, y), line);
    }
    canvas.drawCircle(lensCenter, lensRadius, Paint()..color = glass);
    canvas.drawLine(
      handleStart,
      handleEnd,
      Paint()
        ..color = Brand.accent
        ..strokeWidth = handleStroke
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      lensCenter,
      lensRadius,
      Paint()
        ..color = Brand.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = lensStroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(AppLogoPainter old) => old.withBackground != withBackground;
}
