import 'package:pdfrx/pdfrx.dart';

import '../models/document_ref.dart';

/// Asks the user for a password. Return null to cancel.
typedef PasswordRequest = Future<String?> Function({required bool retry});

/// Failure categories shown to the user (never raw exception text).
enum OpenFailure {
  notFound, tooLarge, tooManyPages, notPdf, corrupted, wrongPassword, cancelled, timeout,

  /// Pre-scan found a decompression bomb or similar: "This file looks unsafe
  /// or too complex to open" (see core/security/pdf_prescan.dart).
  unsafe,
}

class DocumentOpenException implements Exception {
  const DocumentOpenException(this.failure, [this.detail]);
  final OpenFailure failure;
  final String? detail;
  @override
  String toString() => 'DocumentOpenException($failure${detail == null ? '' : ': $detail'})';
}

/// The single entry point for opening untrusted PDFs. Implementations MUST
/// enforce SecurityLimits (size, page count, timeout) and map all engine
/// errors to [DocumentOpenException].
abstract interface class DocumentService {
  /// Copies/validates [path] and returns a stable [DocumentRef].
  Future<DocumentRef> importFile(String path, {String? displayName, String? sourceUri});

  Future<PdfDocument> open(DocumentRef ref, {PasswordRequest? askPassword});
}
