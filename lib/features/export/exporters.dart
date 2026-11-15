import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/export/exporter.dart';
import '../../core/models/export_job.dart';
import '../../core/providers.dart';
import 'docx_exporter.dart';
import 'image_exporter.dart';
import 'pdf_exporter.dart';
import 'text_exporter.dart';

/// All on-device exporters, wired to shared services.
List<Exporter> buildExporters(Ref ref) {
  final temp = ref.watch(tempFilesProvider);
  return [
    PdfExporter(temp, () => ref.read(pageEditorProvider)),
    ImageExporter(temp, flatten: (doc, annotations) => ref.read(pageEditorProvider).flatten(doc, annotations)),
    TextExporter(temp),
    DocxExporter(temp),
  ];
}

/// The exporter handling [format], or null.
Exporter? exporterFor(List<Exporter> exporters, ExportFormat format) {
  for (final e in exporters) {
    if (e.formats.contains(format)) return e;
  }
  return null;
}
