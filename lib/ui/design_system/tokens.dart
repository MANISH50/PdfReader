import 'package:material_ui/material_ui.dart';

/// Design tokens. Use these instead of literal numbers/colours in widgets.
abstract final class Space {
  static const double xxs = 2, xs = 4, sm = 8, md = 16, lg = 24, xl = 32, xxl = 48, xxxl = 64;
}

abstract final class Radii {
  static const double xs = 4, sm = 8, md = 14, lg = 22, xl = 28;
  static const BorderRadius card = BorderRadius.all(Radius.circular(md));
  static const BorderRadius tile = BorderRadius.all(Radius.circular(sm + 2));
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  /// Delay between consecutive items of a staggered entrance.
  static const Duration stagger = Duration(milliseconds: 35);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// Respect the OS "reduce motion" setting.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;

  /// True when the OS asks for reduced motion.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Minimum touch target (Material 48dp; iOS HIG 44pt — we use the larger).
const double kMinTouchTarget = 48;

/// Max width of readable content columns (settings, onboarding text) on large screens.
const double kMaxContentWidth = 720;

abstract final class Brand {
  /// Deep indigo accent. Contrast vs white is 5.7:1 (AA for text); on dark
  /// surfaces the generated tonal palette supplies lighter primaries instead.
  static const Color seed = Color(0xFF3B5BDB);

  /// Darker end of the icon/illustration gradient.
  static const Color seedDeep = Color(0xFF2A3FA6);

  /// Warm accent used for the lens mark in the logo and illustrations.
  static const Color accent = Color(0xFFFFB547);

  /// Paper white used for the document sheet in the logo.
  static const Color paper = Color(0xFFFFFFFF);

  /// Signature gradient: indigo → violet → pink (headers, primary buttons,
  /// FAB, app icon). White text on it is ≥ 4.5:1 across the whole sweep.
  static const List<Color> gradientColors = [Color(0xFF3B5BDB), Color(0xFF7C3AED), Color(0xFFDB2777)];
  static const List<Color> gradientColorsDark = [Color(0xFF2A3FA6), Color(0xFF5B21B6), Color(0xFF9D174D)];

  static LinearGradient gradient(
    Brightness b, {
    AlignmentGeometry begin = Alignment.topLeft,
    AlignmentGeometry end = Alignment.bottomRight,
  }) => LinearGradient(begin: begin, end: end, colors: b == Brightness.dark ? gradientColorsDark : gradientColors);

  /// Splash backgrounds (keep in sync with pubspec flutter_native_splash).
  static const Color splashLight = Color(0xFFF6F7FB);
  static const Color splashDark = Color(0xFF0F1115);
}

/// Colour and icon per file type (recents badges, filter chips).
abstract final class FileTypeStyle {
  static const pdf = Color(0xFFE5484D);
  static const word = Color(0xFF2F6FED);
  static const excel = Color(0xFF16A34A);
  static const csv = Color(0xFF0D9488);
  static const markdown = Color(0xFF8B5CF6);
  static const text = Color(0xFF64748B);

  /// Colour for a badge label (PDF, DOC, XLS, CSV, MD, TXT).
  static Color color(String badge) => switch (badge) {
    'PDF' => pdf,
    'DOC' => word,
    'XLS' => excel,
    'CSV' => csv,
    'MD' => markdown,
    _ => text,
  };

  static IconData icon(String badge) => switch (badge) {
    'PDF' => Icons.picture_as_pdf_rounded,
    'DOC' => Icons.article_rounded,
    'XLS' => Icons.grid_on_rounded,
    'CSV' => Icons.table_rows_rounded,
    'MD' => Icons.tag_rounded,
    _ => Icons.notes_rounded,
  };
}

/// Soft, tinted shadow used by cards and floating bars.
List<BoxShadow> softShadow(ColorScheme s, {double strength = 1}) => [
  BoxShadow(
    color: (s.brightness == Brightness.dark ? Colors.black : s.primary).withValues(
      alpha: (s.brightness == Brightness.dark ? 0.35 : 0.10) * strength,
    ),
    blurRadius: 18,
    offset: const Offset(0, 6),
  ),
];

/// Breakpoints for adaptive layouts.
enum WindowSize { compact, medium, expanded }

WindowSize windowSizeOf(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w < 600) return WindowSize.compact;
  if (w < 840) return WindowSize.medium;
  return WindowSize.expanded;
}

/// Horizontal page padding that centres content in a [maxWidth] column on
/// wide windows while keeping a comfortable gutter on phones.
double contentGutter(BuildContext context, {double maxWidth = kMaxContentWidth}) {
  final w = MediaQuery.sizeOf(context).width;
  final base = windowSizeOf(context) == WindowSize.compact ? Space.md : Space.lg;
  final centred = (w - maxWidth) / 2;
  return centred > base ? centred : base;
}
