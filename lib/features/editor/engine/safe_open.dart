import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

import '../../../core/models/document_ref.dart';
import '../../../core/pdf/document_service.dart';
import '../../../core/security/limits.dart';

/// Opens [ref] via the app's [DocumentService] when available. If that
/// service is not wired (it is built by another feature), falls back to a
/// direct open that still enforces [SecurityLimits] (size, timeout, pages).
Future<PdfDocument> openWithLimits(
  DocumentRef ref, {
  DocumentService? service,
  PasswordRequest? askPassword,
}) async {
  if (service != null) return service.open(ref, askPassword: askPassword);
  return openPathWithLimits(ref.path);
}

Future<PdfDocument> openPathWithLimits(String path) async {
  final f = File(path);
  if (!await f.exists()) throw const DocumentOpenException(OpenFailure.notFound);
  if (await f.length() > SecurityLimits.maxFileBytes) throw const DocumentOpenException(OpenFailure.tooLarge);
  final PdfDocument doc;
  try {
    doc = await PdfDocument.openFile(path).timeout(SecurityLimits.openTimeout);
  } on PdfPasswordException {
    throw const DocumentOpenException(OpenFailure.wrongPassword);
  } on DocumentOpenException {
    rethrow;
  } catch (e) {
    throw DocumentOpenException(OpenFailure.corrupted, e.runtimeType.toString());
  }
  if (doc.pages.length > SecurityLimits.maxPages || doc.pages.isEmpty) {
    await doc.dispose();
    throw const DocumentOpenException(OpenFailure.tooManyPages);
  }
  return doc;
}
