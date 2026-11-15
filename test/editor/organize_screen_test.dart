import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/features/editor/organize_screen.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_fixtures.dart';

/// Lets real async work (FFI worker, file IO) progress between frames.
Future<void> settleReal(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await t.pump();
  }
}

void main() {
  late Directory root;
  setUpAll(() async => pdfrxInitialize());
  setUp(() => root = Directory.systemTemp.createTempSync('org'));
  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('organizer: select, rotate, delete, undo, save as copy', (t) async {
    final bytes = await t.runAsync(() => makePdf(3));
    PdfDocument? doc;
    const ref = DocumentRef(id: 'x', path: '/nonexistent.pdf', displayName: 'Doc.pdf', sizeBytes: 1);
    await t.pumpWidget(ProviderScope(
      overrides: [appDirsProvider.overrideWithValue(AppDirs(root))],
      child: MaterialApp(
        home: OrganizeScreen(
          document: ref,
          opener: (_) async => doc = await PdfDocument.openData(Uint8List.fromList(bytes!)),
        ),
      ),
    ));
    await settleReal(t, () => find.byKey(const ValueKey('page-cell-0')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('page-cell-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-cell-2')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('page-cell-1')));
    await t.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('organize-rotate-right')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('organize-delete')));
    await t.pump();
    expect(find.byKey(const ValueKey('page-cell-1')), findsNothing);
    await t.tap(find.byKey(const ValueKey('organize-undo')));
    await t.pump();
    expect(find.byKey(const ValueKey('page-cell-1')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('organize-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Save as copy'));
    await settleReal(t, () => Directory('${root.path}/documents').existsSync() &&
        Directory('${root.path}/documents').listSync().whereType<File>().any((f) => f.path.endsWith('.pdf')));
    final saved = Directory('${root.path}/documents').listSync().whereType<File>().where((f) => f.path.endsWith('.pdf')).toList();
    expect(saved, hasLength(1));
    final out = await t.runAsync(() => PdfDocument.openFile(saved.single.path));
    expect(out!.pages.length, 3);
    expect(out.pages[1].rotation, PdfPageRotation.clockwise90);
    await t.runAsync(out.dispose);

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(doc, isNotNull);
  });
}
