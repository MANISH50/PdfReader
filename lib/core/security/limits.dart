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

  // ---- Reader (DOCX / Markdown / text) ------------------------------------

  /// Largest text or Markdown file the reader opens.
  static const int maxTextFileBytes = 20 * 1024 * 1024;

  /// Largest DOCX file the reader opens.
  static const int maxDocxFileBytes = 100 * 1024 * 1024;

  /// DOCX (untrusted ZIP) limits: entries, uncompressed sizes, time budget.
  static const int maxDocxEntries = 2000;
  static const int maxDocxXmlBytes = 50 * 1024 * 1024;
  static const int maxDocxImageBytes = 20 * 1024 * 1024;
  static const int maxDocxTotalBytes = 150 * 1024 * 1024;
  /// Spreadsheet caps (CSV/TSV/XLSX). Past a cap the sheet is cut short
  /// and the reader says so.
  static const int maxSheetRows = 100000;
  static const int maxSheetColumns = 1000;
  static const int maxSheetCells = 2000000;
  static const int maxSheetCellChars = 32767;
  static const int maxSheets = 100;

  static const Duration readerOpenTimeout = Duration(seconds: 15);
}
