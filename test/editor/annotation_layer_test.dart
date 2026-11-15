import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/core/storage/stores.dart';
import 'package:pdfreader/features/editor/annotation_controller.dart';
import 'package:pdfreader/features/editor/editor_tools.dart';
import 'package:pdfreader/features/editor/model/page_transform.dart';
import 'package:pdfreader/features/editor/widgets/annotation_layer.dart';
import 'package:pdfreader/features/editor/widgets/editing_toolbar.dart';

void main() {
  late Directory dir;
  late AnnotationController c;
  late EditorToolState tool;
  const pageSize = Size(300, 400); // PDF pt; rendered at 1:1

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('layer');
    c = AnnotationController(docId: 'd', store: AnnotationStore(JsonStore(dir)), autosaveDelay: const Duration(days: 1));
    tool = EditorToolState();
  });
  tearDown(() {
    tool.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> finish(WidgetTester t) async {
    await t.runAsync(c.flush);
    c.dispose();
  }

  Widget harness({VoidCallback? onBackgroundTap}) => MaterialApp(
        home: Scaffold(
          body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: pageSize.width,
              height: pageSize.height,
              child: Stack(children: [
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('viewer'),
                    onTap: onBackgroundTap,
                    child: const ColoredBox(color: Colors.white),
                  ),
                ),
                Positioned.fill(
                  child: AnnotationLayer(
                    page: 1,
                    pageSize: pageSize,
                    transform: pdfToViewMatrix(pageSize: pageSize, quarterTurns: 0, viewSize: pageSize),
                    controller: c,
                    tool: tool,
                  ),
                ),
              ]),
            ),
            EditingToolbar(tool: tool, controller: c),
          ]),
        ),
      );

  testWidgets('pen draws an ink stroke; undo/redo buttons work', (t) async {
    await t.pumpWidget(harness());
    await t.tap(find.byKey(const ValueKey('tool-ink')));
    await t.pump();
    expect(tool.tool, EditorTool.ink);
    final g = await t.startGesture(const Offset(50, 50));
    for (var i = 1; i <= 10; i++) {
      await g.moveBy(const Offset(10, 5));
      await t.pump();
    }
    await g.up();
    await t.pumpAndSettle();
    expect(c.annotations.single, isA<InkAnnotation>());
    final ink = c.annotations.single as InkAnnotation;
    // View (50,50) → PDF (50, 350): y flipped.
    expect(ink.strokes.single.first.dx, closeTo(50, 15));
    expect(ink.strokes.single.first.dy, closeTo(350, 15));

    await t.tap(find.byKey(const ValueKey('toolbar-undo')));
    await t.pumpAndSettle();
    expect(c.annotations, isEmpty);
    await t.tap(find.byKey(const ValueKey('toolbar-redo')));
    await t.pumpAndSettle();
    expect(c.annotations, hasLength(1));
    await finish(t);
  });

  testWidgets('select mode only claims pointers over annotations; drag moves; delete', (t) async {
    var viewerTaps = 0;
    await t.pumpWidget(harness(onBackgroundTap: () => viewerTaps++));
    await c.add(const ShapeAnnotation(id: 'r', page: 1, color: Color(0xFFFF0000), shape: ShapeKind.rectangle,
        bounds: Rect.fromLTRB(100, 200, 200, 300), strokeWidth: 2));
    tool.tool = EditorTool.select;
    await t.pump();

    // Empty area: falls through to the viewer.
    await t.tapAt(const Offset(20, 380));
    await t.pump();
    expect(viewerTaps, 1);
    expect(c.selectedId, isNull);

    // Inside rectangle (view y = 400 - 250 = 150): selects.
    await t.tapAt(const Offset(150, 150));
    await t.pumpAndSettle();
    expect(c.selectedId, 'r');
    expect(viewerTaps, 1);

    await t.dragFrom(const Offset(150, 150), const Offset(30, 0));
    await t.pumpAndSettle();
    final moved = c.byId('r')! as ShapeAnnotation;
    expect(moved.bounds.left, closeTo(130, 6));

    await t.tap(find.byKey(const ValueKey('toolbar-delete')));
    await t.pumpAndSettle();
    expect(c.annotations, isEmpty);
    await finish(t);
  });

  testWidgets('read mode ignores pointers', (t) async {
    var viewerTaps = 0;
    await t.pumpWidget(harness(onBackgroundTap: () => viewerTaps++));
    await c.add(const NoteAnnotation(id: 'n', page: 1, color: Color(0xFFFFD400), anchor: Offset(10, 390), text: 'x'));
    await t.pump();
    await t.tapAt(const Offset(15, 15));
    expect(viewerTaps, 1);
    await finish(t);
  });

  testWidgets('note tool asks for text and places a note', (t) async {
    await t.pumpWidget(harness());
    tool.tool = EditorTool.note;
    await t.pump();
    await t.tapAt(const Offset(100, 100));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('text-input-field')), 'Remember this');
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    final n = c.annotations.single as NoteAnnotation;
    expect(n.text, 'Remember this');
    expect(n.anchor.dy, closeTo(300, 1));
    await finish(t);
  });
}
