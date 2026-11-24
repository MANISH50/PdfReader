import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/app_router.dart';
import 'package:pdfreader/core/documents/document_kind.dart';
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/features/reader/csv_parser.dart';
import 'package:pdfreader/features/reader/docx_parser.dart';
import 'package:pdfreader/features/reader/reader_model.dart';
import 'package:pdfreader/features/reader/reader_screen.dart';
import 'package:pdfreader/features/reader/sheet_view.dart';
import 'package:pdfreader/features/reader/text_markdown_parser.dart';
import 'package:pdfreader/ui/design_system/app_theme.dart';

import '../helpers/fakes.dart';
import '../ui/helpers.dart' show MemoryJsonStore;
import 'fixtures.dart';

DocumentRef _ref(String name, DocumentKind kind) =>
    DocumentRef(id: 'id_$name', path: '/inbox/$name', displayName: name, sizeBytes: 10, kind: kind);

class _Pumped {
  _Pumped(this.store, this.share, this.opened);
  final MemoryJsonStore store;
  final FakeShareService share;
  final List<Uri> opened;
}

Future<_Pumped> _pump(WidgetTester tester, DocumentRef doc, ReaderDocument Function() parse) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = MemoryJsonStore();
  final share = FakeShareService();
  final opened = <Uri>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [jsonStoreProvider.overrideWithValue(store), shareServiceProvider.overrideWithValue(share)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: ReaderScreen(
          document: doc,
          loader: (_) async => parse(),
          urlOpener: (u) async {
            opened.add(u);
            return true;
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Pumped(store, share, opened);
}

Future<void> _search(WidgetTester tester, String q) async {
  await tester.tap(find.byKey(const Key('reader.search')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('reader.search.field')), q);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

String _count(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('reader.search.count'))).data!;

Finder _rich(String text) => find.textContaining(text, findRichText: true);

void main() {
  testWidgets('text: renders lines, search counts and steps through hits, shares, saves position', (tester) async {
    const log = '10:00 start\n10:01 ERROR disk\n10:02 ok\n10:03 error again, error!\n';
    final h = await _pump(tester, _ref('server.log', DocumentKind.text), () => parsePlainText(log, monospace: true));
    expect(find.text('server.log'), findsOneWidget);
    expect(_rich('10:01 ERROR disk'), findsOneWidget);

    await _search(tester, 'error');
    expect(_count(tester), '1 of 3');
    await tester.tap(find.byKey(const Key('reader.search.next')));
    await tester.pumpAndSettle();
    expect(_count(tester), '2 of 3');
    await tester.tap(find.byKey(const Key('reader.search.prev')));
    await tester.tap(find.byKey(const Key('reader.search.prev')));
    await tester.pumpAndSettle();
    expect(_count(tester), '3 of 3');
    await tester.enterText(find.byKey(const Key('reader.search.field')), 'nothing-here');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_count(tester), 'No matches');
    await tester.tap(find.byKey(const Key('reader.search.close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('reader.share')));
    await tester.pump();
    expect(h.share.shared.single.paths, ['/inbox/server.log']);

    // Text options: size slider and page theme.
    await tester.tap(find.byKey(const Key('reader.textOptions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader.fontSize')), findsOneWidget);
    expect(find.byKey(const Key('reader.wrap')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reader.theme.night')));
    await tester.pumpAndSettle();
    final scaffold = tester.widget<Scaffold>(find.byKey(const Key('reader.screen')));
    expect(scaffold.backgroundColor, const Color(0xFF000000));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(h.store.data['state_id_server.log'], isNotNull);
  });

  testWidgets('markdown: renders blocks, remote image is a placeholder, links go through confirm', (tester) async {
    const src = '''
# Guide

Intro with **bold** text.

- apple
- banana

| Col A | Col B |
|---|---|
| x1 | y1 |

```
let code = 1;
```

![tracking pixel](https://tracker.example/p.png)

[Open the site](https://example.com/docs)

[Other file](other.md)

[Jump](#guide)
''';
    final h = await _pump(tester, _ref('guide.md', DocumentKind.markdown), () => parseMarkdown(src));
    expect(_rich('Guide'), findsWidgets);
    expect(_rich('banana'), findsOneWidget);
    expect(_rich('Col B'), findsOneWidget);
    expect(_rich('let code = 1;'), findsOneWidget);
    expect(find.byKey(const Key('reader.imagePlaceholder')), findsOneWidget);
    expect(find.byType(Image), findsNothing); // nothing is ever loaded

    await tester.tapOnText(find.textRange.ofSubstring('Open the site'));
    await tester.pumpAndSettle();
    expect(find.text('Open link?'), findsOneWidget);
    expect(find.text('https://example.com/docs'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.opened, isEmpty);

    await tester.tapOnText(find.textRange.ofSubstring('Open the site'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(h.opened, [Uri.parse('https://example.com/docs')]);

    final r = tester.getRect(_rich('Other file'));
    await tester.tapAt(r.centerLeft + const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(find.text('Open link?'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);

    await _search(tester, 'an');
    expect(_count(tester), '1 of 2'); // "banana" has two non-overlapping "an"
  });

  testWidgets('docx: notice, table, image and search', (tester) async {
    await _pump(tester, _ref('Report.docx', DocumentKind.docx), () => parseDocx(sampleDocx()));
    expect(find.text(docxNotice), findsOneWidget);
    expect(_rich('Quarterly report'), findsOneWidget);
    expect(_rich('Alpha'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(_rich('Page break'), findsOneWidget);
    await _search(tester, 'step');
    expect(_count(tester), '1 of 2');
  });

  testWidgets('load failure shows a friendly message', (tester) async {
    await _pump(
      tester,
      _ref('bad.docx', DocumentKind.docx),
      () => throw const ReaderOpenException(ReaderFailure.unsafe),
    );
    expect(find.text('This file looks unsafe or too complex to open.'), findsOneWidget);
  });

  test('documents route to the viewer or the reader by kind', () {
    expect(documentRouteFor(_ref('a.pdf', DocumentKind.pdf)), Routes.viewer);
    for (final k in [DocumentKind.docx, DocumentKind.markdown, DocumentKind.text]) {
      expect(documentRouteFor(_ref('a', k)), Routes.reader);
    }
  });

  testWidgets('sheet: grid, tabs, cross-sheet search, tap cell to copy', (tester) async {
    final csv = parseDelimited('Name,Qty\nApple,3\nPear,5\n').sheets!.single;
    final doc = ReaderDocument(
      kind: DocumentKind.sheet,
      sheets: [
        csv,
        const SheetData(
          name: 'Second',
          rows: [
            ['x', 'pear tree'],
          ],
          columnCount: 2,
        ),
      ],
    );
    await _pump(tester, _ref('fruit.xlsx', DocumentKind.sheet), () => doc);
    expect(find.byType(SheetView), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Apple'), findsOneWidget);
    expect(find.text('B'), findsOneWidget); // column letter
    expect(find.byKey(const Key('reader.sheetTabs')), findsOneWidget);

    await _search(tester, 'pear');
    expect(_count(tester), '1 of 2');
    await tester.tap(find.byKey(const Key('reader.search.next')));
    await tester.pumpAndSettle();
    expect(_count(tester), '2 of 2');
    expect(find.text('pear tree'), findsOneWidget); // switched to the second sheet
    await tester.tap(find.byKey(const Key('reader.search.close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('reader.sheetTab.0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader.cell.text')), findsOneWidget);
    expect(find.text('A2'), findsOneWidget);
  });
}
