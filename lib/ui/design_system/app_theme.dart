import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// App chrome themes (not page colours — see reading_theme.dart).
///
/// Material 3 everywhere, with Cupertino page transitions on Apple
/// platforms; controls switch to Cupertino via `adaptive.dart`.
/// [highContrast] raises the tonal contrast (wire into
/// `MaterialApp.highContrastTheme` / `highContrastDarkTheme`).
abstract final class AppTheme {
  static ThemeData light({bool highContrast = false}) =>
      _build(Brightness.light, highContrast: highContrast);
  static ThemeData dark({bool highContrast = false}) =>
      _build(Brightness.dark, highContrast: highContrast);

  static ColorScheme scheme(Brightness b, {bool highContrast = false}) {
    final base = ColorScheme.fromSeed(
      seedColor: Brand.seed,
      brightness: b,
      contrastLevel: highContrast ? 1.0 : 0.0,
    );
    // Slightly cooler, calmer surfaces than the default tonal spot.
    return b == Brightness.dark && !highContrast
        ? base.copyWith(surface: const Color(0xFF111318))
        : base;
  }

  /// Typography scale: system fonts (Roboto / SF), tightened display sizes,
  /// semibold titles, relaxed body line height for reading comfort.
  static TextTheme textTheme(ColorScheme s) {
    final base = (s.brightness == Brightness.dark ? Typography.material2021().white : Typography.material2021().black)
        .apply(bodyColor: s.onSurface, displayColor: s.onSurface);
    return base.copyWith(
      displaySmall: base.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.8),
      headlineLarge: base.headlineLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
      headlineMedium: base.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3),
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
      titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: base.bodyLarge?.copyWith(height: 1.45, letterSpacing: 0.1),
      bodyMedium: base.bodyMedium?.copyWith(height: 1.4, letterSpacing: 0.1),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
      labelMedium: base.labelMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.4),
    );
  }

  static ThemeData _build(Brightness b, {required bool highContrast}) {
    final s = scheme(b, highContrast: highContrast);
    final text = textTheme(s);
    const buttonShape = RoundedRectangleBorder(borderRadius: Radii.card);
    const buttonMin = Size(kMinTouchTarget, 52);
    return ThemeData(
      useMaterial3: true,
      colorScheme: s,
      textTheme: text,
      scaffoldBackgroundColor: s.surface,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: s.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: s.onSurface,
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: s.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.card,
          side: BorderSide(color: s.outlineVariant.withValues(alpha: highContrast ? 1 : 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        minVerticalPadding: Space.sm,
        minTileHeight: 56,
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.md),
        iconColor: s.onSurfaceVariant,
        shape: const RoundedRectangleBorder(borderRadius: Radii.card),
        titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500, color: s.onSurface),
        subtitleTextStyle: text.bodyMedium?.copyWith(color: s.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: buttonMin,
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
          textStyle: text.labelLarge?.copyWith(fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: buttonMin,
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
          textStyle: text.labelLarge?.copyWith(fontSize: 16),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(kMinTouchTarget, kMinTouchTarget),
          shape: buttonShape,
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(kMinTouchTarget, kMinTouchTarget)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 4,
        highlightElevation: 2,
        backgroundColor: s.primary,
        foregroundColor: s.onPrimary,
        extendedTextStyle: text.labelLarge?.copyWith(fontSize: 16),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.lg))),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(kMinTouchTarget, kMinTouchTarget),
          textStyle: text.labelLarge,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: s.surfaceContainerHigh,
        border: const OutlineInputBorder(borderRadius: Radii.pill, borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm + 4),
        hintStyle: text.bodyLarge?.copyWith(color: s.onSurfaceVariant),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(s.surfaceContainerHigh),
        constraints: const BoxConstraints(minHeight: 52),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.md)),
        hintStyle: WidgetStatePropertyAll(text.bodyLarge?.copyWith(color: s.onSurfaceVariant)),
        textStyle: WidgetStatePropertyAll(text.bodyLarge),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: Radii.card),
        backgroundColor: s.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: s.onInverseSurface),
        actionTextColor: s.inversePrimary,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: s.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheet),
        clipBehavior: Clip.antiAlias,
        dragHandleColor: s.onSurfaceVariant.withValues(alpha: 0.5),
        constraints: const BoxConstraints(maxWidth: 640),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: s.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.xl))),
        titleTextStyle: text.headlineSmall,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: s.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Radii.card),
      ),
      dividerTheme: DividerThemeData(color: s.outlineVariant.withValues(alpha: 0.6), thickness: 1, space: 1),
      sliderTheme: const SliderThemeData(showValueIndicator: ShowValueIndicator.onDrag),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: s.primary),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(color: s.inverseSurface, borderRadius: Radii.tile),
        textStyle: text.bodySmall?.copyWith(color: s.onInverseSurface),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}
