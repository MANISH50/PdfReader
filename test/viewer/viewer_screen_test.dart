import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/features/viewer/viewer_dialogs.dart';
import 'package:pdfreader/features/viewer/viewer_screen.dart';
import 'package:pdfrx/pdfrx.dart';

class FakeService implements DocumentService {
  FakeService(this.onOpen);
  final Future<PdfDocument> Function(PasswordRequest? ask) onOpen;
  int opens = 0;
  @override
  Future<DocumentRef> importFile(String path, {String? displayName, String? sourceUri}) =>
      throw UnimplementedError();
  @override
  Future<PdfDocument> open(DocumentRef ref, {PasswordRequest? askPassword}) {
    opens++;
    return onOpen(askPassword);
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('viewer_ui'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const doc = DocumentRef(id: 'abc', path: '/x/doc.pdf', displayName: 'Report.pdf', sizeBytes: 10);

  Widget app(DocumentService svc, {DocumentRef document = doc}) => ProviderScope(
        overrides: [
          appDirsProvider.overrideWithValue(AppDirs(tmp)),
          documentServiceProvider.overrideWithValue(svc),
        ],
        child: MaterialApp(home: ViewerScreen(document: document)),
      );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  for (final f in OpenFailure.values) {
    testWidgets('shows friendly error for $f', (tester) async {
      final svc = FakeService((_) async => throw DocumentOpenException(f, 'raw engine detail'));
      await tester.pumpWidget(app(svc));
      await settle(tester);
      final d = describeFailure(f);
      expect(find.text(d.title), findsOneWidget);
      expect(find.textContaining('raw engine detail'), findsNothing);
      expect(find.text('Back'), findsOneWidget);
      if (d.canRetry) {
        await tester.tap(find.byType(FilledButton));
        await settle(tester);
        expect(svc.opens, 2);
      }
    });
  }

  testWidgets('password dialog: retry hint, entered value reaches the engine', (tester) async {
    final got = <String?>[];
    final svc = FakeService((ask) async {
      got.add(await ask!(retry: false));
      got.add(await ask(retry: true));
      throw const DocumentOpenException(OpenFailure.cancelled);
    });
    await tester.pumpWidget(app(svc));
    await settle(tester);
    expect(find.text('Password required'), findsOneWidget);
    expect(find.text('Incorrect password. Try again.'), findsNothing);
    await tester.enterText(find.byKey(const Key('password.field')), 'hunter2');
    await tester.tap(find.text('Open'));
    await settle(tester);
    expect(find.text('Incorrect password. Try again.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(got, ['hunter2', null]);
    expect(find.text('Password needed'), findsOneWidget);
  });

  testWidgets('external link confirmation shows the full URL', (tester) async {
    final uri = Uri.parse('https://example.com/a/very/long/path?with=query&and=more#frag');
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () async => result = await confirmExternalLink(c, uri),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(uri.toString()), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('go to page dialog validates range', (tester) async {
    int? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () async => result = await showGoToPageDialog(c, current: 1, pageCount: 12),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('viewer.goToPage.field')), '40');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a number from 1 to 12'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('viewer.goToPage.field')), '7');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(result, 7);
  });

  testWidgets('opens a real document: page indicator, bookmark, recents, text mode, state flush', (tester) async {
    late PdfDocument pdf;
    late File file;
    await tester.runAsync(() async {
      await pdfrxInitialize();
      final d = pw.Document();
      for (final t in ['One', 'Two', 'Three']) {
        d.addPage(pw.Page(build: (_) => pw.Text(t)));
      }
      file = File('${tmp.path}/real.pdf')..writeAsBytesSync(await d.save());
      pdf = await PdfDocument.openFile(file.path);
    });
    final real = DocumentRef(id: 'real', path: file.path, displayName: 'Real.pdf', sizeBytes: 1);
    await tester.pumpWidget(app(FakeService((_) async => pdf), document: real));
    await settle(tester);
    expect(find.byKey(const Key('viewer.pageIndicator')), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.byType(PdfViewer), findsOneWidget);

    expect(find.byKey(const Key('viewer.scroll')), findsOneWidget);
    expect(find.byKey(const Key('viewer.page.1')), findsOneWidget);
    expect(find.byKey(const Key('viewer.screen')), findsOneWidget);

    // Search: hit count uses the QA key and "i of n" format.
    await tester.tap(find.byKey(const Key('viewer.search')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('viewer.search.field')), 'Two');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    expect(tester.widget<Text>(find.byKey(const Key('viewer.search.count'))).data, '1 of 1');
    await tester.tap(find.byTooltip('Close search'));
    await settle(tester);

    // Bookmark current page.
    await tester.tap(find.byTooltip('Bookmark this page'));
    await settle(tester);
    expect(find.byTooltip('Remove bookmark from this page'), findsOneWidget);
    final stateFile = File('${tmp.path}/data/state_real.json');
    expect(stateFile.existsSync(), isTrue);
    expect(stateFile.readAsStringSync(), contains('"bookmarks":[1]'));

    // Recents updated on open.
    expect(File('${tmp.path}/data/recents.json').readAsStringSync(), contains('Real.pdf'));

    // Switch to text mode via the display sheet.
    await tester.tap(find.byTooltip('Reading mode, page colour and text size'));
    await settle(tester);
    await tester.tap(find.text('Text'));
    await settle(tester);
    expect(find.byType(PdfViewer), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await settle(tester);
    expect(find.textContaining('One'), findsWidgets);

    // Leave the screen: state flushed and document disposed without errors.
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(stateFile.readAsStringSync(), contains('"mode":"reflow"'));
  });
}
