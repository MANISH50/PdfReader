import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/platform/file_pick_service_impl.dart';
import 'package:pdfreader/platform/share_service_impl.dart';
import 'package:share_plus/share_plus.dart';

final class _FakeFile extends PlatformFile {
  _FakeFile(this.name, this.bytes, {this.reportSize = true});
  @override
  final String name;
  final Uint8List bytes;
  final bool reportSize;

  @override
  Uri get uri => Uri.parse('content://picker/$name');
  @override
  XFile get xFile => XFile.fromData(bytes, name: name);
  @override
  int? lengthSync() => reportSize ? bytes.length : null;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() async* {
    for (var i = 0; i < bytes.length; i += 4) {
      yield Uint8List.sublistView(bytes, i, (i + 4).clamp(0, bytes.length));
    }
  }
}

class _FakePicker implements FilePickerApi {
  List<PlatformFile> toPick = [];
  bool? lastMultiple;
  int cleared = 0;
  Uri? saveResult;
  String? savedName;
  Uint8List? savedBytes;
  String? savedMime;

  @override
  Future<List<PlatformFile>> pickPdfs({required bool multiple}) async {
    lastMultiple = multiple;
    return toPick;
  }

  @override
  Future<List<PlatformFile>> pickAny() async {
    lastMultiple = false;
    return toPick;
  }

  @override
  Future<Uri?> saveFile({required String fileName, required Uint8List bytes, required String mimeType}) async {
    savedName = fileName;
    savedBytes = bytes;
    savedMime = mimeType;
    return saveResult;
  }

  @override
  Future<void> clearTemporaryFiles() async => cleared++;
}

void main() {
  late Directory tmp;
  late String inbox;
  late _FakePicker picker;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pick_test');
    inbox = p.join(tmp.path, 'inbox');
    picker = _FakePicker();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('PluginFilePickService.pickDocuments', () {
    test('keeps the document extension (docx, md, txt) and clears the cache', () async {
      final data = Uint8List.fromList(List.generate(10, (i) => i));
      final s = PluginFilePickService(inboxPath: inbox, api: picker);
      for (final (name, want) in [('../Notes.md', 'Notes.md'), ('Report.docx', 'Report.docx'), ('scan', 'scan.pdf')]) {
        picker.toPick = [_FakeFile(name, data)];
        final paths = await s.pickDocuments();
        expect(p.basename(paths.single), want);
        expect(p.isWithin(inbox, paths.single), isTrue);
      }
      expect(picker.cleared, 3);
    });
  });

  group('PluginFilePickService.pickPdfs', () {
    test('copies picked files into the inbox and clears the picker cache', () async {
      final data = Uint8List.fromList(List.generate(10, (i) => i));
      picker.toPick = [_FakeFile('../../evil name.pdf', data), _FakeFile('scan', data, reportSize: false)];
      final s = PluginFilePickService(inboxPath: inbox, api: picker);
      final paths = await s.pickPdfs(multiple: true);
      expect(picker.lastMultiple, isTrue);
      expect(paths, hasLength(2));
      for (final path in paths) {
        expect(p.isWithin(inbox, path), isTrue);
        expect(File(path).readAsBytesSync(), data);
      }
      expect(p.basename(paths[0]), 'evil name.pdf');
      expect(p.basename(paths[1]), 'scan.pdf');
      expect(picker.cleared, 1);
    });

    test('cancel returns empty list', () async {
      final s = PluginFilePickService(inboxPath: inbox, api: picker);
      expect(await s.pickPdfs(), isEmpty);
      expect(picker.cleared, 1);
    });

    test('enforces the size cap while streaming and leaves nothing behind', () async {
      picker.toPick = [_FakeFile('big.pdf', Uint8List(20), reportSize: false)];
      final s = PluginFilePickService(inboxPath: inbox, maxBytes: 10, api: picker);
      await expectLater(s.pickPdfs(), throwsA(isA<PickedFileTooLargeException>()));
      expect(Directory(inbox).listSync(), isEmpty);
      expect(picker.cleared, 1);
    });

    test('rejects up front when the picker reports a size over the cap', () async {
      picker.toPick = [_FakeFile('big.pdf', Uint8List(20))];
      final s = PluginFilePickService(inboxPath: inbox, maxBytes: 10, api: picker);
      await expectLater(s.pickPdfs(), throwsA(isA<PickedFileTooLargeException>()));
    });
  });

  group('PluginFilePickService.saveAs', () {
    test('passes bytes, sanitised name and mime; returns destination', () async {
      final src = File(p.join(tmp.path, 'out.pdf'))..writeAsBytesSync([1, 2, 3]);
      picker.saveResult = Uri.parse('content://docs/123');
      final s = PluginFilePickService(inboxPath: inbox, api: picker);
      final dest = await s.saveAs(src.path, suggestedName: '../My Doc.pdf');
      expect(picker.savedName, 'My Doc.pdf');
      expect(picker.savedBytes, [1, 2, 3]);
      expect(picker.savedMime, 'application/pdf');
      expect(dest, 'My Doc.pdf');
    });

    test('adds the source extension when the name has none; null on cancel', () async {
      final src = File(p.join(tmp.path, 'page.png'))..writeAsBytesSync([1]);
      final s = PluginFilePickService(inboxPath: inbox, api: picker);
      expect(await s.saveAs(src.path, suggestedName: 'Page 1'), isNull);
      expect(picker.savedName, 'Page 1.png');
      expect(picker.savedMime, 'image/png');
    });
  });

  group('SharePlusShareService', () {
    test('shares files with mime types, subject and an iPad origin', () async {
      final f = File(p.join(tmp.path, 'a.pdf'))..writeAsBytesSync([1]);
      ShareParams? got;
      final s = SharePlusShareService(
        share: (params) async => got = params,
        windowSize: () => const Size(800, 600),
      );
      await s.shareFiles([f.path], subject: 'Doc');
      expect(got!.files!.single.path, f.path);
      expect(got!.files!.single.mimeType, 'application/pdf');
      expect(got!.subject, 'Doc');
      expect(got!.sharePositionOrigin!.center, const Offset(400, 300));
      expect(got!.downloadFallbackEnabled, isFalse);
      expect(got!.mailToFallbackEnabled, isFalse);
    });

    test('explicit origin wins; empty list is a no-op; missing file throws', () async {
      final f = File(p.join(tmp.path, 'b.png'))..writeAsBytesSync([1]);
      var calls = 0;
      ShareParams? got;
      final s = SharePlusShareService(share: (params) async {
        calls++;
        got = params;
      });
      await s.shareFiles([]);
      expect(calls, 0);
      const origin = Rect.fromLTWH(1, 2, 3, 4);
      await s.shareFiles([f.path], origin: origin);
      expect(got!.sharePositionOrigin, origin);
      expect(got!.files!.single.mimeType, 'image/png');
      await expectLater(s.shareFiles([p.join(tmp.path, 'nope.pdf')]), throwsA(isA<FileSystemException>()));
    });
  });
}
