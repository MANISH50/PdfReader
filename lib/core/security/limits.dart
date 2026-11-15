/// Hard limits applied to every untrusted PDF. Tuned for mid-range phones.
abstract final class SecurityLimits {
  /// Refuse files larger than this outright.
  static const int maxFileBytes = 2 * 1024 * 1024 * 1024; // 2 GiB

  /// Refuse documents with more pages than this.
  static const int maxPages = 20000;

  /// Max rendered bitmap size for one page/tile, in pixels (~ 64 MB RGBA).
  static const int maxRenderPixels = 16 * 1024 * 1024;

  /// Max PDF page dimension we will honour, in points (PDF spec limit is 14400).
  static const double maxPageSidePt = 14400;

  static const Duration openTimeout = Duration(seconds: 30);
  static const Duration pageRenderTimeout = Duration(seconds: 15);
  static const Duration pageTextTimeout = Duration(seconds: 10);

  /// Max characters extracted from one page (search/reflow/export).
  static const int maxCharsPerPage = 200000;

  /// Max pages merged in one operation.
  static const int maxMergeInputs = 50;
}
