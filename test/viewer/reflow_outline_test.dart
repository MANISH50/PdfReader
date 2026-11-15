import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/core/models/reading_state.dart';
import 'package:pdfreader/features/viewer/reflow_view.dart';
import 'package:pdfreader/features/viewer/viewer_panels.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  group('ReflowView', () {
    Widget host(GlobalKey<ReflowViewState> key, {int initial = 50, List<int>? changes}) => MaterialApp(
          home: Scaffold(
            body: ReflowView(
              key: key,
              pageCount: 60,
              loadText: (p) async => 'Text of page $p.',
              theme: PageTheme.sepia,
              fontScale: 1,
              initialPage: initial,
              onPageChanged: changes?.add,
            ),
          ),
        );

    Finder scrollable() =>
        find.descendant(of: find.byKey(const Key('viewer.scroll')), matching: find.byType(Scrollable)).first;

    testWidgets('opening at page 50 keeps earlier pages reachable', (tester) async {
      final key = GlobalKey<ReflowViewState>();
      final changes = <int>[];
      await tester.pumpWidget(host(key, changes: changes));
      await tester.pumpAndSettle();
      expect(find.text('Page 50'), findsOneWidget);
      expect(find.text('Text of page 50.'), findsOneWidget);
      expect(find.text('Page 1'), findsNothing);

      await tester.scrollUntilVisible(find.text('Page 48'), -300, scrollable: scrollable());
      await tester.pumpAndSettle();
      expect(find.text('Text of page 48.'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Page 1'), -400, scrollable: scrollable(), maxScrolls: 400);
      await tester.pumpAndSettle();
      expect(find.text('Text of page 1.'), findsOneWidget);
      expect(changes, isNotEmpty);
      expect(changes.last, lessThan(10));
    });

    testWidgets('jumpToPage re-anchors and both directions still work', (tester) async {
      final key = GlobalKey<ReflowViewState>();
      await tester.pumpWidget(host(key, initial: 1));
      await tester.pumpAndSettle();
      expect(find.text('Page 1'), findsOneWidget);
      key.currentState!.jumpToPage(30);
      await tester.pumpAndSettle();
      expect(find.text('Page 30'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Page 29'), -300, scrollable: scrollable());
      expect(find.text('Page 29'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Page 33'), 300, scrollable: scrollable());
      expect(find.text('Page 33'), findsOneWidget);
    });
  });

  group('outline', () {
    PdfOutlineNode node(String t, [List<PdfOutlineNode> children = const []]) =>
        PdfOutlineNode(title: t, dest: const PdfDest(1, PdfDestCommand.fit, null), children: children);

    test('only expanded subtrees are flattened', () {
      final tree = [
        node('A', [node('A1'), node('A2', [node('A2a')])]),
        node('B'),
      ];
      expect(flattenOutline(tree, {}).map((r) => r.node.title), ['A', 'B']);
      final rows = flattenOutline(tree, {'0', '0.1'});
      expect(rows.map((r) => r.node.title), ['A', 'A1', 'A2', 'A2a', 'B']);
      expect(rows.map((r) => r.depth), [0, 1, 1, 2, 0]);
    });

    test('huge outlines are capped', () {
      final tree = [for (var i = 0; i < 100000; i++) node('n$i')];
      expect(flattenOutline(tree, {}).length, kMaxOutlineRows);
    });

    test('depth is capped', () {
      var n = node('leaf');
      for (var i = 0; i < 100; i++) {
        n = node('d$i', [n]);
      }
      final expanded = <String>{};
      var path = '0';
      for (var i = 0; i < 100; i++) {
        expanded.add(path);
        path = '$path.0';
      }
      expect(flattenOutline([n], expanded).length, kMaxOutlineDepth);
    });

    testWidgets('OutlineList renders lazily and expands on tap', (tester) async {
      final tree = [
        node('Chapter 1', [node('Section 1.1')]),
        for (var i = 2; i < 2000; i++) node('Chapter $i'),
      ];
      PdfOutlineNode? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: OutlineList(loadOutline: () async => tree, onSelect: (n) => picked = n)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Chapter 1999'), findsNothing); // not built
      expect(find.text('Section 1.1'), findsNothing);
      await tester.tap(find.byTooltip('Expand Chapter 1'));
      await tester.pumpAndSettle();
      expect(find.text('Section 1.1'), findsOneWidget);
      await tester.tap(find.text('Section 1.1'));
      expect(picked?.title, 'Section 1.1');
    });
  });
}
