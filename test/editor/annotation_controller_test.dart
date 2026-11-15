import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/core/commands/undo_stack.dart';
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/core/storage/stores.dart';
import 'package:pdfreader/features/editor/annotation_controller.dart';
import 'package:pdfreader/features/editor/model/annotation_ops.dart';
import 'package:pdfreader/features/editor/model/page_transform.dart';

void main() {
  late Directory dir;
  late AnnotationStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('annot');
    store = AnnotationStore(JsonStore(dir));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AnnotationController make() =>
      AnnotationController(docId: 'doc1', store: store, autosaveDelay: const Duration(milliseconds: 10));

  final samples = <Annotation>[
    const NoteAnnotation(id: 'n', page: 1, color: Color(0xFFFFD400), anchor: Offset(10, 700), text: 'hi'),
    const InkAnnotation(id: 'i', page: 1, color: Color(0xFF000000), strokeWidth: 2, strokes: [
      [Offset(0, 0), Offset(10, 10), Offset(20, 0)]
    ]),
    const ShapeAnnotation(id: 's', page: 2, color: Color(0xFFFF0000), shape: ShapeKind.arrow,
        bounds: Rect.fromLTRB(100, 100, 50, 200), strokeWidth: 2),
    const TextBoxAnnotation(id: 't', page: 1, color: Color(0xFF000000),
        bounds: Rect.fromLTRB(10, 10, 110, 40), text: 'box', fontSize: 12),
    const SignatureAnnotation(id: 'g', page: 3, color: Color(0xFF000000),
        bounds: Rect.fromLTRB(10, 10, 110, 40), signatureId: 'abcd1234'),
  ];

  test('every command type undoes and redoes', () async {
    final c = make();
    await c.load();
    final undo = c.undoStack;
    for (final a in samples) {
      await c.add(a);
    }
    await c.addTextMarkup(page: 1, kind: MarkupKind.highlight, color: const Color(0xFFFFFF00),
        rects: [const Rect.fromLTRB(10, 120, 50, 100)], text: 'word');
    expect(c.annotations, hasLength(6));
    final markup = c.annotations.last as TextMarkupAnnotation;
    expect(markup.rects.single, const Rect.fromLTRB(10, 100, 50, 120)); // normalised

    // Add undo/redo
    await undo.undo();
    expect(c.annotations, hasLength(5));
    await undo.redo();
    expect(c.annotations, hasLength(6));

    // Move
    await c.move('n', const Offset(5, -5));
    expect((c.byId('n')! as NoteAnnotation).anchor, const Offset(15, 695));
    await undo.undo();
    expect((c.byId('n')! as NoteAnnotation).anchor, const Offset(10, 700));
    await undo.redo();
    expect((c.byId('n')! as NoteAnnotation).anchor, const Offset(15, 695));

    // Resize
    await c.resize('t', const Rect.fromLTRB(10, 10, 210, 70));
    expect((c.byId('t')! as TextBoxAnnotation).bounds, const Rect.fromLTRB(10, 10, 210, 70));
    await undo.undo();
    expect((c.byId('t')! as TextBoxAnnotation).bounds, const Rect.fromLTRB(10, 10, 110, 40));

    // Recolor + edit text
    await c.recolor('i', const Color(0xFF00FF00));
    await c.editText('t', 'changed');
    expect(c.byId('i')!.color, const Color(0xFF00FF00));
    expect((c.byId('t')! as TextBoxAnnotation).text, 'changed');
    await undo.undo();
    await undo.undo();
    expect(c.byId('i')!.color, const Color(0xFF000000));
    expect((c.byId('t')! as TextBoxAnnotation).text, 'box');

    // Delete keeps position on undo
    final before = [for (final a in c.annotations) a.id];
    c.select('i');
    await c.removeSelected();
    expect(c.byId('i'), isNull);
    expect(c.selectedId, isNull);
    await undo.undo();
    expect([for (final a in c.annotations) a.id], before);

    expect(c.forPage(1).map((a) => a.id), containsAll(['n', 'i', 't']));
    await c.flush();
    c.dispose();
  });

  test('persists (debounced autosave) and round-trips through the store', () async {
    final c = make();
    await c.load();
    for (final a in samples) {
      await c.add(a);
    }
    expect(c.hasPendingSave, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final c2 = make();
    await c2.load();
    expect([for (final a in c2.annotations) a.toJson()], [for (final a in samples) a.toJson()]);
    await c.remove('n');
    await c.flush();
    final c3 = make();
    await c3.load();
    expect(c3.annotations, hasLength(samples.length - 1));
    c.dispose();
    c2.dispose();
    c3.dispose();
  });

  test('dispose flushes pending writes', () async {
    final c = AnnotationController(docId: 'doc2', store: store, undoStack: UndoStack(), autosaveDelay: const Duration(hours: 1));
    await c.load();
    await c.add(samples.first);
    c.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await store.load('doc2'), hasLength(1));
  });

  group('geometry', () {
    test('hit testing', () {
      final ink = samples[1];
      expect(hitTestAnnotation(ink, const Offset(10, 9), 2), isTrue);
      expect(hitTestAnnotation(ink, const Offset(10, 40), 2), isFalse);
      final arrow = samples[2];
      expect(hitTestAnnotation(arrow, const Offset(75, 150), 2), isTrue);
      expect(hitTestAnnotation(arrow, const Offset(60, 110), 2), isFalse);
      expect(hitTestAll(samples, const Offset(50, 25), 1)?.id, 'g'); // topmost wins
    });

    test('directional shapes keep direction when moved', () {
      final moved = translateAnnotation(samples[2], const Offset(1, 1)) as ShapeAnnotation;
      expect(moved.bounds, const Rect.fromLTRB(101, 101, 51, 201));
    });

    test('pdfToViewMatrix maps corners for every rotation', () {
      const page = Size(200, 100);
      // Unrotated: PDF (0,100) (top-left) → (0,0); (200,0) → view bottom-right.
      var m = pdfToViewMatrix(pageSize: page, quarterTurns: 0, viewSize: const Size(400, 200));
      expect(transformPoint(m, const Offset(0, 100)), const Offset(0, 0));
      expect(transformPoint(m, const Offset(200, 0)), const Offset(400, 200));
      // 90° cw: displayed 100x200; PDF top-left goes to top-right.
      m = pdfToViewMatrix(pageSize: page, quarterTurns: 1, viewSize: const Size(100, 200));
      expect(transformPoint(m, const Offset(0, 100)), const Offset(100, 0));
      expect(transformPoint(m, const Offset(0, 0)), const Offset(0, 0));
      m = pdfToViewMatrix(pageSize: page, quarterTurns: 2, viewSize: const Size(200, 100));
      expect(transformPoint(m, const Offset(0, 100)), const Offset(200, 100));
      m = pdfToViewMatrix(pageSize: page, quarterTurns: 3, viewSize: const Size(100, 200));
      expect(transformPoint(m, const Offset(0, 100)), const Offset(0, 200));
      expect(matrixScale(pdfToViewMatrix(pageSize: page, quarterTurns: 0, viewSize: const Size(400, 200))), 2);
    });

    test('stroke smoothing and simplification', () {
      final pts = [for (var i = 0; i < 50; i++) Offset(i * 0.1, 0)];
      expect(simplifyStroke(pts).length, lessThan(pts.length));
      expect(simplifyStroke(pts).last, pts.last);
      final segs = smoothStroke(const [Offset(0, 0), Offset(10, 10), Offset(20, 0)]);
      expect(segs.first, isA<MoveSeg>());
      expect(segs.whereType<QuadSeg>(), hasLength(1));
    });
  });
}
