import 'package:material_ui/material_ui.dart';

/// UI copy for "Make PdfReader your PDF app".
///
/// NOTE(lead): the Platform agent owns `lib/platform/default_app_info.dart`
/// with similar content; reconcile into one source when merging.
class DefaultAppGuide {
  const DefaultAppGuide({required this.title, required this.intro, required this.steps, this.note, this.tip});

  final String title;
  final String intro;
  final List<String> steps;

  /// Platform caveat shown as an info box.
  final String? note;

  /// Optional extra hint shown under the steps.
  final String? tip;
}

const androidDefaultAppGuide = DefaultAppGuide(
  title: 'Make PdfReader your PDF app',
  intro: 'Set it once and every PDF you tap opens here.',
  steps: [
    'Open the Files app (or your downloads, email or chat) and tap any PDF.',
    'When Android asks which app to use, choose “Open with”, then PdfReader.',
    'Tap “Always” so PDFs open in PdfReader every time.',
  ],
  tip: 'Not asked? Another app is already the default. Go to Settings › Apps › '
      '(your current PDF app) › Open by default › Clear defaults, then tap a PDF again.',
  note: 'You can also use Share › PdfReader from any app.',
);

const iosDefaultAppGuide = DefaultAppGuide(
  title: 'Open PDFs with PdfReader',
  intro: 'Send any PDF to PdfReader from the apps you already use.',
  steps: [
    'Open the PDF in Files, Mail, Safari or Messages.',
    'Tap the Share button (the square with an arrow).',
    'Choose PdfReader in the row of apps. Don’t see it? Swipe to the end and tap More.',
  ],
  tip: 'In Files, you can also long-press a PDF, tap Share, then PdfReader.',
  note: 'iOS doesn’t let any app become the system-wide default for PDFs, so you '
      'pick PdfReader from the Share or “Open in” menu. Your recent files stay in the library.',
);

const desktopDefaultAppGuide = DefaultAppGuide(
  title: 'Open PDFs with PdfReader',
  intro: 'Make PdfReader the app your computer uses for PDFs.',
  steps: [
    'Right-click (or Control-click) any PDF file.',
    'Choose “Open with”, then pick PdfReader.',
    'Select the option to always use this app for PDF files.',
  ],
);

DefaultAppGuide defaultAppGuideFor(TargetPlatform p) => switch (p) {
      TargetPlatform.android || TargetPlatform.fuchsia => androidDefaultAppGuide,
      TargetPlatform.iOS => iosDefaultAppGuide,
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => desktopDefaultAppGuide,
    };
