import 'reading_state.dart';

enum AppThemeMode { system, light, dark }

class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.defaultPageTheme = PageTheme.light,
    this.defaultReadingMode = ReadingMode.continuous,
    this.onboardingDone = false,
    this.keepScreenOn = true,
    this.textScale = 1.0,
  });

  final AppThemeMode themeMode;
  final PageTheme defaultPageTheme;
  final ReadingMode defaultReadingMode;
  final bool onboardingDone;
  final bool keepScreenOn;

  /// Extra scale for app UI text (on top of the OS setting) for reflow/text mode.
  final double textScale;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    PageTheme? defaultPageTheme,
    ReadingMode? defaultReadingMode,
    bool? onboardingDone,
    bool? keepScreenOn,
    double? textScale,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        defaultPageTheme: defaultPageTheme ?? this.defaultPageTheme,
        defaultReadingMode: defaultReadingMode ?? this.defaultReadingMode,
        onboardingDone: onboardingDone ?? this.onboardingDone,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        textScale: textScale ?? this.textScale,
      );

  Map<String, Object?> toJson() => {
        'themeMode': themeMode.name,
        'defaultPageTheme': defaultPageTheme.name,
        'defaultReadingMode': defaultReadingMode.name,
        'onboardingDone': onboardingDone,
        'keepScreenOn': keepScreenOn,
        'textScale': textScale,
      };

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
        themeMode: AppThemeMode.values.asNameMap()[j['themeMode']] ?? AppThemeMode.system,
        defaultPageTheme: PageTheme.values.asNameMap()[j['defaultPageTheme']] ?? PageTheme.light,
        defaultReadingMode:
            ReadingMode.values.asNameMap()[j['defaultReadingMode']] ?? ReadingMode.continuous,
        onboardingDone: j['onboardingDone'] == true,
        keepScreenOn: j['keepScreenOn'] != false,
        textScale: ((j['textScale'] as num?)?.toDouble() ?? 1.0).clamp(0.8, 2.0),
      );
}
