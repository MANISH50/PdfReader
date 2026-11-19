import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../documents/document_kind.dart';
import '../models/document_ref.dart';
import '../security/limits.dart';
import '../security/pdf_prescan.dart';
import 'document_service.dart';

/// Opens a PDF file with the engine. Seam for tests; the default uses
/// [PdfDocument.openFile] with progressive loading, so the call returns as
/// soon as the first page is measured and the viewer can paint it.
typedef PdfFileOpener = Future<PdfDocument> Function(
  String path, {
  required PdfPasswordProvider passwordProvider,
});

Future<PdfDocument> _defaultOpener(String path, {required PdfPasswordProvider passwordProvider}) =>
    PdfDocument.openFile(
      path,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: true,
      useProgressiveLoading: true,
    );

/// [DocumentService] backed by pdfrx / PDFium.
///
/// * [importFile] validates the file in place (size limit, `%PDF-` header
///   within the first 1024 bytes) and derives a stable id from
///   sha256(size + first 64 KiB + last 64 KiB). It never copies: files from
///   other apps are already copied to the private inbox by the platform layer.
/// * [open] enforces the size and page-count limits and a timeout that does not
///   count time spent waiting for the user to type a password. Every failure
///   becomes a [DocumentOpenException]; raw engine messages never reach the UI.
class PdfrxDocumentService implements DocumentService {
  PdfrxDocumentService({
    PdfFileOpener? opener,
    this.openTimeout = SecurityLimits.openTimeout,
    this.maxFileBytes = SecurityLimits.maxFileBytes,
    this.maxPages = SecurityLimits.maxPages,
    this.maxPasswordAttempts = 5,
    Future<PdfPrescanResult> Function(String path)? prescan,
  })  : _opener = opener ?? _defaultOpener,
        _prescan = prescan ?? prescanPdf;

  final PdfFileOpener _opener;

  /// Decompression-bomb pre-scan run (in a background isolate) before PDFium
  /// sees the file. See core/security/pdf_prescan.dart.
  final Future<PdfPrescanResult> Function(String path) _prescan;
  final Duration openTimeout;
  final int maxFileBytes;
  final int maxPages;
  final int maxPasswordAttempts;

  static const int headerScanBytes = 1024;
  static const int hashChunkBytes = 64 * 1024;

  @override
  Future<DocumentRef> importFile(String path, {String? displayName, String? sourceUri}) async {
    final file = File(path);
    final int size;
    try {
      if (!await file.exists()) throw const DocumentOpenException(OpenFailure.notFound);
      size = await file.length();
    } on FileSystemException {
      throw const DocumentOpenException(OpenFailure.notFound);
    }
    // Tiny files can't be PDFs but can be text: the PDF minimum applies below.
    if (size > maxFileBytes) throw DocumentOpenException(OpenFailure.tooLarge, '$size bytes');
    final RandomAccessFile raf;
    try {
      raf = await file.open();
    } on FileSystemException {
      throw const DocumentOpenException(OpenFailure.notFound);
    }
    try {
      final head = await _readAt(raf, 0, hashChunkBytes < size ? hashChunkBytes : size);
      var kind = DocumentKind.pdf;
      if (hasPdfHeader(head)) {
        _checkSize(size);
      } else {
        // Not a PDF: maybe a DOCX / Markdown / text file for the reader.
        // A file named .pdf without a PDF header is still "not a PDF".
        if (documentExtension(path, displayName: displayName) == '.pdf') {
          throw const DocumentOpenException(OpenFailure.notPdf);
        }
        final sniffed = await sniffDocumentKind(path, displayName: displayName);
        if (sniffed == null || sniffed == DocumentKind.pdf) {
          throw const DocumentOpenException(OpenFailure.unsupported);
        }
        final cap = sniffed == DocumentKind.docx ? SecurityLimits.maxDocxFileBytes : SecurityLimits.maxTextFileBytes;
        if (size > cap) throw const DocumentOpenException(OpenFailure.tooLarge);
        kind = sniffed;
      }
      final tailLen = hashChunkBytes < size ? hashChunkBytes : size;
      final tail = await _readAt(raf, size - tailLen, tailLen);
      return DocumentRef(
        kind: kind,
        id: computeId(size, head, tail),
        path: path,
        displayName: (displayName == null || displayName.trim().isEmpty)
            ? p.basename(path)
            : displayName.trim(),
        sizeBytes: size,
        sourceUri: sourceUri,
      );
    } on FileSystemException {
      throw const DocumentOpenException(OpenFailure.notFound);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<PdfDocument> open(DocumentRef ref, {PasswordRequest? askPassword}) async {
    final file = File(ref.path);
    final int size;
    try {
      if (!await file.exists()) throw const DocumentOpenException(OpenFailure.notFound);
      size = await file.length();
    } on FileSystemException {
      throw const DocumentOpenException(OpenFailure.notFound);
    }
    _checkSize(size);
    try {
      final raf = await file.open();
      try {
        final head = await _readAt(raf, 0, headerScanBytes < size ? headerScanBytes : size);
        if (!hasPdfHeader(head)) throw const DocumentOpenException(OpenFailure.notPdf);
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      throw const DocumentOpenException(OpenFailure.notFound);
    }

    // PDFium has no allocation limit; refuse decompression bombs up front.
    (await _prescan(ref.path)).throwIfUnsafe();

    final attempt = _OpenAttempt(openTimeout);
    var asked = 0;
    var cancelled = false;
    var exhausted = false;

    Future<String?> provider() async {
      // The attempt already timed out: never pop a dialog over the error.
      if (attempt.isDone) return null;
      if (askPassword == null) {
        exhausted = true; // password required but nobody can supply one
        return null;
      }
      if (asked >= maxPasswordAttempts) {
        exhausted = true;
        return null;
      }
      final retry = asked > 0;
      asked++;
      attempt.pause();
      final String? pw;
      try {
        pw = await askPassword(retry: retry);
      } finally {
        attempt.resume();
      }
      if (pw == null) cancelled = true;
      return pw;
    }

    final PdfDocument doc;
    try {
      doc = await attempt.run(() => _opener(ref.path, passwordProvider: provider));
    } on TimeoutException {
      throw const DocumentOpenException(OpenFailure.timeout);
    } on PdfPasswordException {
      if (cancelled && !exhausted) throw const DocumentOpenException(OpenFailure.cancelled);
      throw const DocumentOpenException(OpenFailure.wrongPassword);
    } on DocumentOpenException {
      rethrow;
    } on FileSystemException {
      throw const DocumentOpenException(OpenFailure.notFound);
    } on PdfException catch (e) {
      throw DocumentOpenException(mapPdfiumError(e.errorCode), 'engine error ${e.errorCode}');
    } catch (_) {
      throw const DocumentOpenException(OpenFailure.corrupted);
    }

    final int pageCount;
    try {
      pageCount = doc.pages.length;
    } catch (_) {
      await _safeDispose(doc);
      throw const DocumentOpenException(OpenFailure.corrupted);
    }
    if (pageCount == 0) {
      await _safeDispose(doc);
      throw const DocumentOpenException(OpenFailure.corrupted, 'no pages');
    }
    if (pageCount > maxPages) {
      await _safeDispose(doc);
      throw DocumentOpenException(OpenFailure.tooManyPages, '$pageCount pages');
    }
    return doc;
  }

  void _checkSize(int size) {
    if (size > maxFileBytes) throw DocumentOpenException(OpenFailure.tooLarge, '$size bytes');
    if (size < 8) throw const DocumentOpenException(OpenFailure.notPdf);
  }

  /// True if `%PDF-` occurs within the first [headerScanBytes] bytes.
  static bool hasPdfHeader(List<int> bytes) {
    const sig = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
    final end = (bytes.length < headerScanBytes ? bytes.length : headerScanBytes) - sig.length;
    outer:
    for (var i = 0; i <= end; i++) {
      for (var j = 0; j < sig.length; j++) {
        if (bytes[i + j] != sig[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// sha256 over the decimal size, a separator, the first and last chunks.
  static String computeId(int size, List<int> head, List<int> tail) {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink)
      ..add(utf8.encode('$size:'))
      ..add(head)
      ..add(tail);
    input.close();
    return sink.value.toString();
  }

  /// FPDF_ERR_* codes → user-facing categories.
  static OpenFailure mapPdfiumError(int? code) => switch (code) {
        2 => OpenFailure.notFound, // FPDF_ERR_FILE
        3 => OpenFailure.corrupted, // FPDF_ERR_FORMAT
        4 => OpenFailure.wrongPassword, // FPDF_ERR_PASSWORD
        _ => OpenFailure.corrupted, // unknown, security handler, page error
      };

  static Future<Uint8List> _readAt(RandomAccessFile raf, int pos, int len) async {
    await raf.setPosition(pos);
    return raf.read(len);
  }

  static Future<void> _safeDispose(PdfDocument doc) async {
    try {
      await doc.dispose();
    } catch (_) {}
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Runs an open with a timeout that can be paused while the user is typing a
/// password. A document that finishes loading after the timeout fired is
/// disposed so it does not leak.
class _OpenAttempt {
  _OpenAttempt(this.timeout);
  final Duration timeout;
  Timer? _timer;
  bool _timedOut = false;
  final _completer = Completer<PdfDocument>();

  bool get isDone => _completer.isCompleted;

  Future<PdfDocument> run(Future<PdfDocument> Function() body) {
    _start();
    body().then((doc) {
      if (_completer.isCompleted) {
        unawaited(PdfrxDocumentService._safeDispose(doc));
      } else {
        _timer?.cancel();
        _completer.complete(doc);
      }
    }, onError: (Object e, StackTrace st) {
      _timer?.cancel();
      if (!_completer.isCompleted) _completer.completeError(e, st);
    });
    return _completer.future;
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer(timeout, () {
      _timedOut = true;
      if (!_completer.isCompleted) _completer.completeError(TimeoutException('open', timeout));
    });
  }

  void pause() => _timer?.cancel();

  void resume() {
    if (!_timedOut && !_completer.isCompleted) _start();
  }
}
