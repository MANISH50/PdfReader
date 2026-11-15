import 'package:pdfrx/pdfrx.dart';

import '../models/annotation.dart';
import '../models/export_job.dart';

/// Converts a document to another format entirely on-device. Implementations
/// run heavy work off the UI isolate, honour SecurityLimits, write only into
/// app-private temp storage, and support cancellation via [isCancelled].
abstract interface class Exporter {
  Set<ExportFormat> get formats;

  Future<ExportResult> export(
    PdfDocument doc,
    ExportOptions options, {
    required String baseName,
    List<Annotation> annotations = const [],
    ExportProgress? onProgress,
    bool Function()? isCancelled,
  });
}
