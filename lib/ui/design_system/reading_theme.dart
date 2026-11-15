import 'package:material_ui/material_ui.dart';

import '../../core/models/reading_state.dart';

/// Colour treatment for rendered PDF pages.
///
/// * light: unchanged.
/// * sepia: warm tint, multiplies toward paper colour.
/// * dark: inverts luminance only (hue-preserving) so photos keep their hues.
/// * night: like dark, but dimmer and warmer for low light.
class ReadingThemeSpec {
  const ReadingThemeSpec({required this.background, this.filter});

  final Color background;
  final ColorFilter? filter;

  static ReadingThemeSpec of(PageTheme t) => switch (t) {
        PageTheme.light => const ReadingThemeSpec(background: Color(0xFFE9E9EB)),
        PageTheme.sepia => const ReadingThemeSpec(
            background: Color(0xFFE8DFC9),
            filter: ColorFilter.matrix(<double>[
              0.393, 0.769, 0.189, 0, 0, //
              0.349, 0.686, 0.168, 0, 0,
              0.272, 0.534, 0.131, 0, 0,
              0, 0, 0, 1, 0,
            ])),
        PageTheme.dark => const ReadingThemeSpec(
            background: Color(0xFF121212), filter: ColorFilter.matrix(_hueKeepInvert)),
        PageTheme.night => const ReadingThemeSpec(
            background: Color(0xFF000000), filter: ColorFilter.matrix(_nightInvert)),
      };

  // Invert luminance while approximately preserving hue (rotate 180° after invert).
  // Derived from: invert * hueRotate(180°). Keeps white→near-black, black→near-white,
  // red stays reddish.
  static const List<double> _hueKeepInvert = <double>[
    0.333, -0.667, -0.667, 0, 255, //
    -0.667, 0.333, -0.667, 0, 255,
    -0.667, -0.667, 0.333, 0, 255,
    0, 0, 0, 1, 0,
  ];

  static const List<double> _nightInvert = <double>[
    0.25, -0.5, -0.5, 0, 200, //
    -0.5, 0.22, -0.5, 0, 185,
    -0.5, -0.5, 0.18, 0, 160,
    0, 0, 0, 1, 0,
  ];
}
