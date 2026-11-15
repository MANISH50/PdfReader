enum ExportFormat { pdf, png, jpg, txt, docx }

extension ExportFormatX on ExportFormat {
  String get extension => switch (this) {
        ExportFormat.pdf => 'pdf',
        ExportFormat.png => 'png',
        ExportFormat.jpg => 'jpg',
        ExportFormat.txt => 'txt',
        ExportFormat.docx => 'docx',
      };

  /// Formats whose output may lose layout fidelity; the UI must warn first.
  bool get isLossyLayout => this == ExportFormat.docx || this == ExportFormat.txt;
}

class ExportOptions {
  const ExportOptions({
    required this.format,
    this.pages,
    this.dpi = 150,
    this.jpgQuality = 90,
    this.includeAnnotations = true,
  });

  final ExportFormat format;

  /// 1-based page numbers; null = all pages.
  final List<int>? pages;
  final int dpi;
  final int jpgQuality;
  final bool includeAnnotations;
}

/// Progress callback: [done] of [total] pages processed.
typedef ExportProgress = void Function(int done, int total);

class ExportResult {
  const ExportResult(this.files);

  /// Output files in app-private temp/export storage. Image exports with
  /// several pages produce one file per page.
  final List<String> files;
}
