import 'dart:math' as math;
import 'dart:ui' show Color;

/// WCAG 2.x contrast helpers, used by tests to guard the palette.
abstract final class Contrast {
  /// Relative luminance per WCAG 2.x (sRGB).
  static double luminance(Color c) {
    double ch(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  /// Contrast ratio between two opaque colours, from 1 to 21.
  static double ratio(Color a, Color b) {
    final la = luminance(a), lb = luminance(b);
    final hi = math.max(la, lb), lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// WCAG AA for normal text.
  static const double aa = 4.5;

  /// WCAG AAA for normal text.
  static const double aaa = 7;
}
