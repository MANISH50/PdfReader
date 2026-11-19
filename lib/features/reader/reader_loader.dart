import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../core/documents/document_kind.dart';
import '../../core/models/document_ref.dart';
import '../../core/security/limits.dart';
import 'docx_parser.dart';
import 'reader_model.dart';
import 'text_markdown_parser.dart';

/// Loads a document for the reader. Injectable for tests.
typedef ReaderLoader = Future<ReaderDocument> Function(DocumentRef doc);

/// Reads and parses [doc] synchronously (call from a background isolate).
ReaderDocument parseReaderFile(String path, DocumentKind kind, String displayName, {ParseBudget? budget}) {
  final f = File(path);
  final int size;
  try {
    size = f.lengthSync();
  } on FileSystemException {
    throw const ReaderOpenException(ReaderFailure.notFound);
  }
  try {
    switch (kind) {
      case DocumentKind.docx:
        return parseDocxFile(path, budget: budget);
      case DocumentKind.markdown:
        if (size > SecurityLimits.maxTextFileBytes) throw const ReaderOpenException(ReaderFailure.tooLarge);
        return parseMarkdown(decodeTextFile(f.readAsBytesSync()), budget: budget);
      case DocumentKind.text:
        if (size > SecurityLimits.maxTextFileBytes) throw const ReaderOpenException(ReaderFailure.tooLarge);
        return parsePlainText(decodeTextFile(f.readAsBytesSync()),
            monospace: isCodeLikeName(displayName), budget: budget);
      case DocumentKind.pdf:
        throw const ReaderOpenException(ReaderFailure.unsupported);
    }
  } on FileSystemException {
    throw const ReaderOpenException(ReaderFailure.notFound);
  }
}

/// Default loader: parses off the UI isolate within the reader time budget.
Future<ReaderDocument> loadReaderDocument(DocumentRef doc) async {
  const limit = SecurityLimits.readerOpenTimeout;
  final path = doc.path, kind = doc.kind, name = doc.displayName;
  try {
    return await Isolate.run(() => parseReaderFile(path, kind, name, budget: ParseBudget(limit)))
        .timeout(limit + const Duration(seconds: 2));
  } on TimeoutException {
    throw const ReaderOpenException(ReaderFailure.timeout);
  } on ReaderOpenException {
    rethrow;
  } catch (_) {
    throw const ReaderOpenException(ReaderFailure.damaged);
  }
}
