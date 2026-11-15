// Fakes for the shared contracts in lib/core and lib/platform, for widget,
// feature and integration tests. They record every call so tests can assert
// on interactions, and never touch the network or shared storage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/export/exporter.dart';
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/models/export_job.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/pdf/page_editor.dart';
import 'package:pdfreader/platform/platform_services.dart';
import 'package:pdfrx/pdfrx.dart';

/// [DocumentService] that opens files with the real engine (pdfrx) but keeps
/// imports in memory. Use [failNextOpen] / [failImport] to simulate errors.
///
/// Real PDF opening needs PDFium: call `initPdfrxForTests()` (unit/widget
/// tests) or `pdfrxFlutterInitialize()` (integration tests) first, or set
/// [opener] to return a stub document.
class FakeDocumentService implements DocumentService {
  FakeDocumentService({this.opener});

  /// Overrides how a [DocumentRef] becomes a [PdfDocument].
  Future<PdfDocument> Function(DocumentRef ref, String? password)? opener;

  final imported = <DocumentRef>[];
  final opened = <DocumentRef>[];
  OpenFailure? failNextOpen;
  OpenFailure? failImport;

  @override
  Future<DocumentRef> importFile(String path, {String? displayName, String? sourceUri}) async {
    if (failImport case final f?) throw DocumentOpenException(f);
    final file = File(path);
    if (!file.existsSync()) throw const DocumentOpenException(OpenFailure.notFound);
    final bytes = await file.readAsBytes();
    final ref = DocumentRef(
      id: sha256.convert([...utf8.encode('${bytes.length}:'), ...bytes.take(65536)]).toString().substring(0, 32),
      path: path,
      displayName: displayName ?? p.basename(path),
      sizeBytes: bytes.length,
      sourceUri: sourceUri,
    );
    imported.add(ref);
    return ref;
  }

  @override
  Future<PdfDocument> open(DocumentRef ref, {PasswordRequest? askPassword}) async {
    if (failNextOpen case final f?) {
      failNextOpen = null;
      throw DocumentOpenException(f);
    }
    String? password;
    var retry = false;
    while (true) {
      try {
        final doc = opener != null
            ? await opener!(ref, password)
            : await PdfDocument.openFile(
                ref.path,
                passwordProvider: password == null ? null : createSimplePasswordProvider(password),
                firstAttemptByEmptyPassword: password == null,
              );
        opened.add(ref);
        return doc;
      } on PdfPasswordException {
        if (askPassword == null) throw const DocumentOpenException(OpenFailure.wrongPassword);
        password = await askPassword(retry: retry);
        if (password == null) throw const DocumentOpenException(OpenFailure.cancelled);
        retry = true;
      } on PdfException catch (e) {
        throw DocumentOpenException(OpenFailure.corrupted, e.message);
      }
    }
  }
}

/// Records [PageEditor] calls and returns [result] bytes.
class FakePageEditor implements PageEditor {
  FakePageEditor({List<int>? result}) : result = result ?? utf8.encode('%PDF-1.7\n%fake\n');

  List<int> result;
  final calls = <String>[];
  final rebuildSpecs = <List<PageSpec>>[];
  final flattened = <List<Annotation>>[];

  @override
  Future<List<int>> rebuild(PdfDocument source, List<PageSpec> pages) async {
    calls.add('rebuild');
    rebuildSpecs.add(pages);
    return result;
  }

  @override
  Future<List<int>> merge(List<PdfDocument> docs) async {
    calls.add('merge:${docs.length}');
    return result;
  }

  @override
  Future<List<List<int>>> split(PdfDocument source, List<List<int>> ranges) async {
    calls.add('split:${ranges.length}');
    return [for (final _ in ranges) result];
  }

  @override
  Future<List<int>> flatten(PdfDocument source, List<Annotation> annotations) async {
    calls.add('flatten');
    flattened.add(annotations);
    return result;
  }
}

/// Writes saved bytes into [dir] and records each save.
class FakeSaveService implements SaveService {
  FakeSaveService(this.dir);

  final Directory dir;
  final saves = <({String path, SaveMode mode, String suggestedName, String? originalPath})>[];

  @override
  Future<String> save(List<int> bytes,
      {required SaveMode mode, required String suggestedName, String? originalPath}) async {
    final target = mode == SaveMode.overwriteOriginal && originalPath != null
        ? originalPath
        : p.join(dir.path, suggestedName);
    await File(target).writeAsBytes(bytes, flush: true);
    saves.add((path: target, mode: mode, suggestedName: suggestedName, originalPath: originalPath));
    return target;
  }
}

/// Exporter that writes one file per requested page into [dir]. For TXT it
/// extracts real text through the engine; other formats get placeholder bytes.
class FakeExporter implements Exporter {
  FakeExporter(this.dir, {Set<ExportFormat>? formats})
      : formats = formats ?? ExportFormat.values.toSet();

  final Directory dir;
  @override
  final Set<ExportFormat> formats;
  final calls = <ExportOptions>[];
  Object? throwOnExport;

  @override
  Future<ExportResult> export(
    PdfDocument doc,
    ExportOptions options, {
    required String baseName,
    List<Annotation> annotations = const [],
    ExportProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls.add(options);
    if (throwOnExport case final e?) throw e;
    final pages = options.pages ?? [for (var i = 1; i <= doc.pages.length; i++) i];
    final files = <String>[];
    if (options.format == ExportFormat.txt) {
      final buf = StringBuffer();
      for (final (i, n) in pages.indexed) {
        if (isCancelled?.call() ?? false) break;
        buf.writeln((await doc.pages[n - 1].loadText())?.fullText ?? '');
        onProgress?.call(i + 1, pages.length);
      }
      final f = File(p.join(dir.path, '$baseName.txt'))..writeAsStringSync(buf.toString());
      files.add(f.path);
    } else {
      for (final (i, n) in pages.indexed) {
        if (isCancelled?.call() ?? false) break;
        final name = pages.length > 1 && !(options.format == ExportFormat.pdf || options.format == ExportFormat.docx)
            ? '${baseName}_$n.${options.format.extension}'
            : '$baseName.${options.format.extension}';
        final f = File(p.join(dir.path, name))..writeAsStringSync('fake ${options.format.name} page $n');
        if (!files.contains(f.path)) files.add(f.path);
        onProgress?.call(i + 1, pages.length);
      }
    }
    return ExportResult(files);
  }
}

class FakeIncomingFileService implements IncomingFileService {
  FakeIncomingFileService({this.initial});

  IncomingFile? initial;
  final _controller = StreamController<IncomingFile>.broadcast();

  /// Simulates another app handing us a file while running.
  void deliver(IncomingFile f) => _controller.add(f);

  @override
  Future<IncomingFile?> initialFile() async {
    final f = initial;
    initial = null;
    return f;
  }

  @override
  Stream<IncomingFile> get files => _controller.stream;

  Future<void> close() => _controller.close();
}

class FakeShareService implements ShareService {
  final shared = <({List<String> paths, String? subject})>[];

  @override
  Future<void> shareFiles(List<String> paths, {String? subject}) async =>
      shared.add((paths: paths, subject: subject));
}

/// Returns queued results; an empty queue behaves like a cancelled picker.
class FakeFilePickService implements FilePickService {
  final pickQueue = <List<String>>[];
  final saveAsQueue = <String?>[];
  final saveAsCalls = <({String sourcePath, String suggestedName})>[];
  int pickCalls = 0;

  @override
  Future<List<String>> pickPdfs({bool multiple = false}) async {
    pickCalls++;
    return pickQueue.isEmpty ? const [] : pickQueue.removeAt(0);
  }

  @override
  Future<String?> saveAs(String sourcePath, {required String suggestedName}) async {
    saveAsCalls.add((sourcePath: sourcePath, suggestedName: suggestedName));
    return saveAsQueue.isEmpty ? null : saveAsQueue.removeAt(0);
  }
}
