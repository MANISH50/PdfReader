import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/pdf/page_editor.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/features/editor/model/text_layout.dart';
import 'package:pdfreader/features/editor/organize/organize_model.dart';
import 'package:pdfreader/features/editor/organize/page_ranges.dart';
import 'package:pdfreader/features/editor/save/file_save_service.dart';

void main() {
  group('page ranges', () {
    test('parses ranges, open ends and descending', () {
      expect(parsePageRanges('1-3, 5; 7-', 8), [
        [1, 2, 3],
        [5],
        [7, 8],
      ]);
      expect(parsePageRanges('-2,4-3', 5), [
        [1, 2],
        [4, 3],
      ]);
    });
    test('rejects bad input', () {
      for (final bad in ['', 'a', '0', '9', '2-x', '1--2']) {
        expect(() => parsePageRanges(bad, 8), throwsFormatException, reason: bad);
      }
    });
    test('chunks and describes', () {
      expect(chunkPages(5, 2), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect(describePages([1, 2, 3, 5, 7, 8]), '1-3, 5, 7-8');
    });
  });

  group('OrganizeModel', () {
    test('move / rotate / delete / append with undo', () async {
      final m = OrganizeModel()..reset(sourceIndex: 0, pageCount: 4);
      expect(m.isModified, isFalse);
      await m.move(0, 3);
      expect(m.items.map((i) => i.pageNumber), [2, 3, 4, 1]);
      expect(m.isModified, isTrue);
      await m.rotate([m.items.first.id], 1);
      await m.rotate([m.items.first.id], -1);
      await m.rotate([m.items.first.id], -1);
      expect(m.items.first.quarterTurns, 3);
      m.toggleSelected(m.items[1].id);
      expect(await m.delete(m.selected), isTrue);
      expect(m.items, hasLength(3));
      expect(m.selected, isEmpty);
      expect(await m.delete(m.items.map((e) => e.id)), isFalse); // never delete all
      await m.append(sourceIndex: 1, pageCount: 2);
      expect(m.items, hasLength(5));
      expect(m.items.last.sourceIndex, 1);
      while (m.undoStack.canUndo) {
        await m.undoStack.undo();
      }
      expect(m.items.map((i) => i.pageNumber), [1, 2, 3, 4]);
      expect(m.items.every((i) => i.quarterTurns == 0), isTrue);
      expect(m.isModified, isFalse);
    });
  });

  group('FileSaveService', () {
    late Directory root;
    late FileSaveService s;
    final pdf = Uint8List.fromList('%PDF-1.7\n%%EOF'.codeUnits);
    setUp(() {
      root = Directory.systemTemp.createTempSync('save');
      s = FileSaveService(AppDirs(root));
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('save as copy uses unique sanitised names in app storage', () async {
      final a = await s.save(pdf, mode: SaveMode.saveAsCopy, suggestedName: '../evil/Report.pdf');
      final b = await s.save(pdf, mode: SaveMode.saveAsCopy, suggestedName: '../evil/Report.pdf');
      expect(p.isWithin(root.path, a), isTrue);
      expect(p.basename(a), 'Report (edited).pdf');
      expect(p.basename(b), 'Report (edited) (2).pdf');
      expect(File(a).readAsBytesSync(), pdf);
    });

    test('overwrite only for app-private files, atomically', () async {
      final inside = File(p.join(root.path, 'inbox', 'a.pdf'))
        ..createSync(recursive: true)
        ..writeAsStringSync('%PDF-old');
      final out = await s.save(pdf, mode: SaveMode.overwriteOriginal, suggestedName: 'a.pdf', originalPath: inside.path);
      expect(out, inside.path);
      expect(inside.readAsBytesSync(), pdf);
      expect(inside.parent.listSync(), hasLength(1)); // no temp leftovers

      final outsideDir = Directory.systemTemp.createTempSync('outside');
      final outside = File(p.join(outsideDir.path, 'b.pdf'))..writeAsStringSync('%PDF-old');
      final res = await s.save(pdf, mode: SaveMode.overwriteOriginal, suggestedName: 'b.pdf', originalPath: outside.path);
      expect(res, isNot(outside.path));
      expect(outside.readAsStringSync(), '%PDF-old');
      outsideDir.deleteSync(recursive: true);
    });

    test('refuses non-PDF output', () {
      expect(() => s.save([1, 2, 3, 4, 5, 6, 7, 8, 9], mode: SaveMode.saveAsCopy, suggestedName: 'x'),
          throwsA(isA<SaveException>()));
    });
  });

  test('text layout wraps on Helvetica metrics', () {
    final lines = wrapText('The quick brown fox jumps over the lazy dog', 12, 100);
    expect(lines.length, greaterThan(1));
    for (final l in lines) {
      expect(helveticaWidth(l, 12), lessThanOrEqualTo(100));
    }
    expect(wrapText('a\nb', 12, 100), ['a', 'b']);
    expect(isWinAnsiEncodable('Café €5'), isTrue);
    expect(isWinAnsiEncodable('日本'), isFalse);
  });
}
