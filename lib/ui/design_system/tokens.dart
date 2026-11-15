import 'package:material_ui/material_ui.dart';

/// Design tokens. Use these instead of literal numbers/colours in widgets.
abstract final class Space {
  static const double xs = 4, sm = 8, md = 16, lg = 24, xl = 32, xxl = 48;
}

abstract final class Radii {
  static const double sm = 8, md = 14, lg = 22;
  static const BorderRadius card = BorderRadius.all(Radius.circular(md));
}

abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// Respect the OS "reduce motion" setting.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}

/// Minimum touch target (Material 48dp; iOS HIG 44pt — we use the larger).
const double kMinTouchTarget = 48;

abstract final class Brand {
  /// Deep indigo-teal accent; checked for >= 4.5:1 contrast on white and on #121212.
  static const Color seed = Color(0xFF3B5BDB);
}

/// Breakpoints for adaptive layouts.
enum WindowSize { compact, medium, expanded }

WindowSize windowSizeOf(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w < 600) return WindowSize.compact;
  if (w < 840) return WindowSize.medium;
  return WindowSize.expanded;
}
