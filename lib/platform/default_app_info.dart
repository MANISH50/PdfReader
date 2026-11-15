import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One instruction step for the onboarding "make PdfReader your PDF app" page.
class DefaultAppStep {
  const DefaultAppStep(this.title, this.detail);
  final String title;
  final String detail;
}

/// Platform-specific guidance for opening PDFs with PdfReader by default.
/// Used by the onboarding screen (UI agent).
class DefaultAppInfo {
  const DefaultAppInfo({
    required this.platform,
    required this.headline,
    required this.steps,
    this.clearDefaultSteps = const [],
    this.note,
    this.canOpenSettings = false,
  });

  final TargetPlatform platform;
  final String headline;

  /// How to open a PDF with PdfReader (and make that stick, where possible).
  final List<DefaultAppStep> steps;

  /// How to remove another app's default (Android only).
  final List<DefaultAppStep> clearDefaultSteps;

  /// Extra explanation, e.g. iOS has no system-wide default PDF viewer.
  final String? note;

  /// Whether [DefaultAppSettings.openForThisApp] can open a settings screen.
  final bool canOpenSettings;

  static DefaultAppInfo forPlatform(TargetPlatform platform) => switch (platform) {
        TargetPlatform.android => android,
        TargetPlatform.iOS => ios,
        _ => desktop(platform),
      };

  /// For the running platform.
  static DefaultAppInfo get current => forPlatform(defaultTargetPlatform);

  static const android = DefaultAppInfo(
    platform: TargetPlatform.android,
    headline: 'Open PDFs with PdfReader',
    steps: [
      DefaultAppStep('Open a PDF', 'In Files, Downloads or any app, tap a PDF.'),
      DefaultAppStep('Choose PdfReader',
          'When Android asks which app to use ("Open with"), pick PdfReader.'),
      DefaultAppStep('Tap "Always"',
          'PDFs will now open in PdfReader. If Android doesn\'t ask, another app is '
              'already the default; clear it first (see below).'),
    ],
    clearDefaultSteps: [
      DefaultAppStep('Open Settings ▸ Apps', 'Find the app that currently opens your PDFs.'),
      DefaultAppStep('Open by default',
          'Tap "Open by default" (or "Set as default") ▸ "Clear defaults".'),
      DefaultAppStep('Open a PDF again', 'Android now asks which app to use: pick PdfReader ▸ Always.'),
    ],
    note: 'You can also share a PDF to PdfReader from any app\'s share menu. '
        'PdfReader keeps a private copy and never uploads anything.',
    canOpenSettings: true,
  );

  static const ios = DefaultAppInfo(
    platform: TargetPlatform.iOS,
    headline: 'Open PDFs with PdfReader',
    steps: [
      DefaultAppStep('Find the PDF', 'In the Files app (or Mail, Safari downloads…), locate the PDF.'),
      DefaultAppStep('Share', 'Long-press the PDF (or open it) and tap Share.'),
      DefaultAppStep('Choose PdfReader',
          'Tap PdfReader in the app row. If it isn\'t shown, tap "More" and add it to your favourites.'),
    ],
    note: 'iOS doesn\'t let you choose a system-wide default app for PDFs, so tapping a PDF '
        'opens Apple\'s built-in preview. Use Share ▸ PdfReader, or open files from inside '
        'PdfReader. PdfReader keeps a private copy and never uploads anything.',
  );

  static DefaultAppInfo desktop(TargetPlatform platform) => DefaultAppInfo(
        platform: platform,
        headline: 'Open PDFs with PdfReader',
        steps: const [
          DefaultAppStep('Open from PdfReader', 'Use the Open button to pick PDFs with the system dialog.'),
        ],
      );
}

/// Opens the system screen where the user manages PdfReader's default links.
class DefaultAppSettings {
  const DefaultAppSettings({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('pdfreader/system');

  final MethodChannel _channel;

  /// Android: "Open by default" for this app (API 31+), otherwise the app's
  /// details page. Returns false where unsupported or if nothing could open.
  Future<bool> openForThisApp() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('openDefaultAppSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Android API level, or null elsewhere.
  Future<int?> androidSdkInt() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _channel.invokeMethod<int>('sdkInt');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
