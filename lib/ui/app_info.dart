/// Static app facts shown in Settings › About. Keep [version] in sync with
/// `version:` in pubspec.yaml (no package_info dependency on purpose).
abstract final class AppInfo {
  static const String name = 'PdfReader';
  static const String version = '1.0.1';
  static const int build = 1;
  static const String tagline = 'Private, offline PDF reader and editor';
}
