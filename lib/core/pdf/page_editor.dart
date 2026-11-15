import 'package:pdfrx/pdfrx.dart';

import '../models/annotation.dart';

/// Page-level operations. All methods produce NEW bytes / documents; the
/// original file is never modified in place. Saving is done by [SaveService].
abstract interface class PageEditor {
  /// Builds a new PDF from [source] with the given page order (1-based page
  /// numbers, may omit pages = delete) and rotations (degrees, multiples of 90).
  Future<List<int>> rebuild(PdfDocument source, List<PageSpec> pages);

  /// Concatenates documents in order.
  Future<List<int>> merge(List<PdfDocument> docs);

  /// Splits into chunks, each a list of 1-based page numbers.
  Future<List<List<int>>> split(PdfDocument source, List<List<int>> ranges);

  /// Burns annotations (and filled form values) into a copy of [source].
  Future<List<int>> flatten(PdfDocument source, List<Annotation> annotations);
}

class PageSpec {
  const PageSpec(this.pageNumber, {this.rotationDegrees = 0});
  final int pageNumber;
  final int rotationDegrees;
}

enum SaveMode { overwriteOriginal, saveAsCopy }

/// Writes edited output. overwriteOriginal must always be confirmed by the UI
/// and is atomic (write temp, fsync, rename). Drafts autosave to app storage.
abstract interface class SaveService {
  Future<String> save(List<int> bytes, {required SaveMode mode, required String suggestedName, String? originalPath});
}
