import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/export/exporter.dart';
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/models/export_job.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/features/export/export_screen.dart';
import 'package:pdfreader/platform/platform_services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'test_pdfs.dart';

class _DocService implements DocumentService {
  _DocService(this.doc);
  final PdfDocument? doc;
  @override
  Future<DocumentRef> importFile(String path, {String? displayName, String? sourceUri}) => throw UnimplementedError();
  @override
  Future<PdfDocument> open(DocumentRef ref, {PasswordRequest? askPassword}) async =>
      doc ?? (throw const DocumentOpenException(OpenFailure.corrupted));
}

class _FakeExporter implements Exporter {
  _FakeExporter(this.dir);
  final Directory dir;
  ExportOptions? last;
  @override
  Set<ExportFormat> get formats => ExportFormat.values.toSet();
  @override
  Future<ExportResult> export(PdfDocument doc, ExportOptions options,
      {required String baseName,
      List<Annotation> annotations = const [],
      ExportProgress? onProgress,
      bool Function()? isCancelled}) async {
    last = options;
    final out = Directory(p.join(dir.path, 'd1'))..createSync(recursive: true);
    final f = File(p.join(out.path, '$baseName.${options.format.extension}'))..writeAsStringSync('x');
    onProgress?.call(1, 1);
    return ExportResult([f.path]);
  }
}

class _Share implements ShareService {
  List<String>? shared;
  @override
  Future<void> shareFiles(List<String> paths, {String? subject}) async => shared = paths;
}

class _Save implements FilePickService {
  @override
  Future<List<String>> pickPdfs({bool multiple = false}) async => [];
  @override
  Future<String?> saveAs(String sourcePath, {required String suggestedName}) => throw StateError('no SAF');
}

void main() {
  const ref = DocumentRef(id: 'id1', path: '/x.pdf', displayName: 'Report.pdf', sizeBytes: 1);

  Future<(_FakeExporter, _Share, Directory)> pump(WidgetTester tester, PdfDocument? doc) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('export_screen_');
    addTearDown(() => root.deleteSync(recursive: true));
    final dirs = AppDirs(root);
    final exporter = _FakeExporter(dirs.temp);
    final share = _Share();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDirsProvider.overrideWithValue(dirs),
        documentServiceProvider.overrideWithValue(_DocService(doc)),
        exportersProvider.overrideWithValue([exporter]),
        shareServiceProvider.overrideWithValue(share),
        filePickServiceProvider.overrideWithValue(_Save()),
      ],
      child: const MaterialApp(home: ExportScreen(document: ref, currentPage: 2)),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    return (exporter, share, dirs.temp);
  }

  testWidgets('open failure shows a friendly message', (tester) async {
    await pump(tester, null);
    expect(find.textContaining("couldn't be opened"), findsOneWidget);
  });

  testWidgets('DOCX shows the honest warning, range validation, export and share', (tester) async {
    final doc = await tester.runAsync(() async {
      await initEngine();
      return openBytes(await buildSamplePdf(pages: 4));
    });
    final (exporter, share, tempDir) = await pump(tester, doc);
    expect(find.text('All pages (4)'), findsOneWidget);
    expect(find.text('Current page (2)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('export.format.docx')));
    await tester.pump();
    expect(find.text(kLossyExportWarning), findsOneWidget);

    await tester.tap(find.text('Page range'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '3-9');
    await tester.pump();
    expect(find.textContaining('does not exist'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2-3');
    await tester.pump();

    await tester.ensureVisible(find.text('Export as Word (DOCX)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export as Word (DOCX)'));
    await tester.pumpAndSettle();
    expect(find.text('Before you convert'), findsOneWidget);
    expect(find.text(kLossyExportWarning), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('export.confirmLossy')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(exporter.last!.format, ExportFormat.docx);
    expect(exporter.last!.pages, [2, 3]);
    expect(find.text('Report.docx'), findsOneWidget);
    expect(find.byKey(const Key('export.done')), findsOneWidget);

    await tester.ensureVisible(find.text('Save to…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(share.shared, hasLength(1));

    await tester.tap(find.text('Save to…'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Saving is not available right now.'), findsOneWidget);

    // Leaving the screen removes the export output.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(tempDir.listSync(recursive: true).whereType<File>(), isEmpty);
  });
}
