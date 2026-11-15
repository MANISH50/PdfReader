import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/core/commands/undo_stack.dart';
import 'package:pdfreader/core/models/annotation.dart';
import 'package:pdfreader/core/models/reading_state.dart';
import 'package:pdfreader/core/security/link_policy.dart';
import 'package:pdfreader/core/storage/app_storage.dart';

void main() {
  group('UndoStack', () {
    test('undo/redo and dirty tracking', () async {
      var v = 0;
      final s = UndoStack();
      Command inc() => FnCommand('inc', () async => v++, () async => v--);
      await s.run(inc());
      await s.run(inc());
      expect(v, 2);
      expect(s.isDirty, isTrue);
      s.markSaved();
      expect(s.isDirty, isFalse);
      await s.undo();
      expect(v, 1);
      expect(s.isDirty, isTrue);
      await s.redo();
      expect(v, 2);
      expect(s.isDirty, isFalse);
      await s.undo();
      await s.run(inc()); // clears redo
      expect(s.canRedo, isFalse);
    });

    test('respects limit', () async {
      final s = UndoStack(limit: 3);
      for (var i = 0; i < 10; i++) {
        await s.run(FnCommand('n', () async {}, () async {}));
      }
      var undos = 0;
      while (s.canUndo) {
        await s.undo();
        undos++;
      }
      expect(undos, 3);
    });
  });

  test('Annotation JSON round-trip for every type', () {
    final items = <Annotation>[
      const TextMarkupAnnotation(
          id: 'a', page: 1, color: Color(0xFFFFEB3B), kind: MarkupKind.highlight,
          rects: [Rect.fromLTRB(1, 2, 3, 4)], text: 'hi'),
      const NoteAnnotation(id: 'b', page: 2, color: Color(0xFF000000), anchor: Offset(5, 6), text: 'n'),
      const InkAnnotation(id: 'c', page: 3, color: Color(0xFF000000), strokeWidth: 2,
          strokes: [[Offset(0, 0), Offset(1, 1)]]),
      const ShapeAnnotation(id: 'd', page: 1, color: Color(0xFF000000), shape: ShapeKind.arrow,
          bounds: Rect.fromLTRB(0, 0, 10, 10), strokeWidth: 1),
      const TextBoxAnnotation(id: 'e', page: 1, color: Color(0xFF000000),
          bounds: Rect.fromLTRB(0, 0, 10, 10), text: 'box', fontSize: 12),
      const SignatureAnnotation(id: 'f', page: 1, color: Color(0xFF000000),
          bounds: Rect.fromLTRB(0, 0, 10, 10), signatureId: 'sig1'),
    ];
    for (final a in items) {
      final b = Annotation.fromJson(a.toJson());
      expect(b.runtimeType, a.runtimeType);
      expect(b.toJson(), a.toJson());
    }
  });

  test('ReadingState JSON round-trip and defaults', () {
    const s = ReadingState(pageNumber: 7, zoom: 1.5, mode: ReadingMode.twoPage, bookmarks: {3, 1});
    final r = ReadingState.fromJson(s.toJson());
    expect(r.pageNumber, 7);
    expect(r.mode, ReadingMode.twoPage);
    expect(r.bookmarks, {1, 3});
    expect(ReadingState.fromJson(const {'mode': 'bogus'}).mode, ReadingMode.continuous);
  });

  group('LinkPolicy', () {
    test('allows only http/https/mailto with confirmation', () {
      expect(LinkPolicy.decide(uri: Uri.parse('https://example.com/a')), LinkDecision.confirmExternal);
      expect(LinkPolicy.decide(uri: Uri.parse('mailto:a@b.c')), LinkDecision.confirmExternal);
      for (final bad in ['javascript:alert(1)', 'file:///etc/passwd', 'intent://x#Intent;end',
          'content://x/y', 'tel:123', 'http:///nohost', 'myapp://x']) {
        expect(LinkPolicy.decide(uri: Uri.parse(bad)), LinkDecision.blocked, reason: bad);
      }
      expect(LinkPolicy.decide(hasInternalDest: true), LinkDecision.internal);
      expect(LinkPolicy.decide(), LinkDecision.blocked);
    });
  });

  group('JsonStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('store'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('read/write/delete and corruption tolerance', () async {
      final s = JsonStore(dir);
      await s.write('k', {'a': 1});
      expect(await s.read('k'), {'a': 1});
      File('${dir.path}/k.json').writeAsStringSync('{not json');
      expect(await s.read('k'), isNull);
      await s.delete('k');
      expect(await s.read('k'), isNull);
    });

    test('rejects path traversal keys', () {
      final s = JsonStore(dir);
      expect(() => s.write('../evil', 1), throwsArgumentError);
      expect(() => s.write('a/b', 1), throwsArgumentError);
    });
  });
}
