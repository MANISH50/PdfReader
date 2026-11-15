import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/pdf/pdfrx_document_service.dart';
import 'package:pdfreader/features/viewer/reflow_view.dart';
import 'package:pdfreader/features/viewer/viewer_hooks.dart';
import 'package:pdfrx/pdfrx.dart';

Future<Uint8List> makePdf(List<String> pages) async {
  final d = pw.Document();
  for (final t in pages) {
    d.addPage(pw.Page(build: (_) => pw.Text(t)));
  }
  return d.save();
}

Matcher failsWith(OpenFailure f) =>
    throwsA(isA<DocumentOpenException>().having((e) => e.failure, 'failure', f));

void main() {
  late Directory tmp;
  setUpAll(() async => pdfrxInitialize());
  setUp(() => tmp = Directory.systemTemp.createTempSync('viewer_svc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  group('importFile', () {
    test('valid PDF gets a stable id independent of path', () async {
      final bytes = await makePdf(['Hello']);
      final a = write('a.pdf', bytes);
      final b = write('b.pdf', bytes);
      final svc = PdfrxDocumentService();
      final ra = await svc.importFile(a.path);
      final rb = await svc.importFile(b.path, displayName: 'Renamed.pdf');
      expect(ra.id, rb.id);
      expect(ra.id, hasLength(64));
      expect(ra.displayName, 'a.pdf');
      expect(rb.displayName, 'Renamed.pdf');
      expect(ra.sizeBytes, bytes.length);
      final other = write('c.pdf', await makePdf(['Different']));
      expect((await svc.importFile(other.path)).id, isNot(ra.id));
    });

    test('header may be preceded by junk within 1024 bytes', () async {
      final bytes = await makePdf(['x']);
      final f = write('junk.pdf', [...List.filled(100, 0x20), ...bytes]);
      await PdfrxDocumentService().importFile(f.path);
      final far = write('far.pdf', [...List.filled(2000, 0x20), ...bytes]);
      await expectLater(PdfrxDocumentService().importFile(far.path), failsWith(OpenFailure.notPdf));
    });

    test('rejects non-PDF, missing and oversized files', () async {
      final svc = PdfrxDocumentService();
      await expectLater(svc.importFile(write('x.pdf', List.filled(4096, 65)).path), failsWith(OpenFailure.notPdf));
      await expectLater(svc.importFile('${tmp.path}/missing.pdf'), failsWith(OpenFailure.notFound));
      final f = write('big.pdf', await makePdf(['x']));
      await expectLater(PdfrxDocumentService(maxFileBytes: 100).importFile(f.path), failsWith(OpenFailure.tooLarge));
    });
  });

  group('open (engine)', () {
    test('opens a valid file and loads text lazily', () async {
      final f = write('ok.pdf', await makePdf(['First page', 'Second page']));
      final svc = PdfrxDocumentService();
      final ref = await svc.importFile(f.path);
      final doc = await svc.open(ref);
      expect(doc.pages.length, 2);
      final text = await pdfPageTextLoader(doc)(2);
      expect(text, contains('Second page'));
      await doc.dispose();
    });

    test('enforces page limit', () async {
      final f = write('two.pdf', await makePdf(['a', 'b']));
      final svc = PdfrxDocumentService(maxPages: 1);
      await expectLater(svc.open(await svc.importFile(f.path)), failsWith(OpenFailure.tooManyPages));
    });

    test('corrupted file maps to corrupted, never a raw exception', () async {
      final f = write('bad.pdf', [...'%PDF-1.7\n'.codeUnits, ...List.filled(3000, 0x41)]);
      final svc = PdfrxDocumentService();
      final ref = DocumentRef(id: 'x', path: f.path, displayName: 'bad.pdf', sizeBytes: 3009);
      await expectLater(svc.open(ref), failsWith(OpenFailure.corrupted));
    });

    test('missing file maps to notFound', () async {
      const ref = DocumentRef(id: 'x', path: '/nonexistent/zzz.pdf', displayName: 'z', sizeBytes: 1);
      await expectLater(PdfrxDocumentService().open(ref), failsWith(OpenFailure.notFound));
    });

    test('page transform round-trips PDF points', () async {
      final f = write('t.pdf', await makePdf(['a']));
      final doc = await PdfDocument.openFile(f.path);
      final page = doc.pages.first;
      final info = ViewerPageInfo(
          page: page, pageRectInViewer: Rect.fromLTWH(10, 20, page.width * 2, page.height * 2));
      expect(info.scale, closeTo(2, 1e-9));
      // Bottom-left PDF origin is the overlay's bottom-left corner.
      expect(info.pdfToLocal(Offset.zero), Offset(0, page.height * 2));
      final back = info.localToPdf(info.pdfToLocal(const Offset(100, 200)));
      expect(back.dx, closeTo(100, 1e-6));
      expect(back.dy, closeTo(200, 1e-6));
      await doc.dispose();
    });
  });

  group('open (password flow, fake engine)', () {
    late File file;
    late DocumentRef ref;
    setUp(() async {
      file = write('p.pdf', await makePdf(['secret']));
      ref = DocumentRef(id: 'p', path: file.path, displayName: 'p.pdf', sizeBytes: file.lengthSync());
    });

    // Emulates pdfrx: empty password first, then asks the provider until it
    // returns the right one or null.
    PdfFileOpener fakeEncrypted(String password, {Duration delay = Duration.zero}) =>
        (path, {required passwordProvider}) async {
          await Future<void>.delayed(delay);
          while (true) {
            final pw = await passwordProvider();
            if (pw == null) throw const PdfPasswordException('No password supplied by PasswordProvider.');
            if (pw == password) return PdfDocument.openFile(path);
          }
        };

    test('asks again with retry=true after a wrong password', () async {
      final retries = <bool>[];
      final answers = ['wrong', 'right'];
      final svc = PdfrxDocumentService(opener: fakeEncrypted('right'));
      final doc = await svc.open(ref, askPassword: ({required bool retry}) async {
        retries.add(retry);
        return answers.removeAt(0);
      });
      expect(retries, [false, true]);
      await doc.dispose();
    });

    test('cancel maps to cancelled', () async {
      final svc = PdfrxDocumentService(opener: fakeEncrypted('right'));
      await expectLater(
          svc.open(ref, askPassword: ({required bool retry}) async => null), failsWith(OpenFailure.cancelled));
    });

    test('too many wrong attempts maps to wrongPassword', () async {
      var n = 0;
      final svc = PdfrxDocumentService(opener: fakeEncrypted('right'), maxPasswordAttempts: 3);
      await expectLater(svc.open(ref, askPassword: ({required bool retry}) async {
        n++;
        return 'nope';
      }), failsWith(OpenFailure.wrongPassword));
      expect(n, 3);
    });

    test('no password callback maps to wrongPassword', () async {
      final svc = PdfrxDocumentService(opener: fakeEncrypted('right'));
      await expectLater(svc.open(ref), failsWith(OpenFailure.wrongPassword));
    });

    test('engine timeout maps to timeout', () async {
      final svc = PdfrxDocumentService(
        opener: (path, {required passwordProvider}) => Completer<PdfDocument>().future,
        openTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(svc.open(ref), failsWith(OpenFailure.timeout));
    });

    test('no password dialog after the open already timed out', () async {
      var asked = false;
      final svc = PdfrxDocumentService(
        opener: fakeEncrypted('right', delay: const Duration(milliseconds: 200)),
        openTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(svc.open(ref, askPassword: ({required bool retry}) async {
        asked = true;
        return 'right';
      }), failsWith(OpenFailure.timeout));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(asked, isFalse);
    });

    test('time spent typing a password does not count toward the timeout', () async {
      final svc = PdfrxDocumentService(
        opener: fakeEncrypted('right'),
        openTimeout: const Duration(milliseconds: 100),
      );
      final doc = await svc.open(ref, askPassword: ({required bool retry}) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return 'right';
      });
      expect(doc.pages, isNotEmpty);
      await doc.dispose();
    });

    test('unexpected engine errors map to corrupted', () async {
      final svc = PdfrxDocumentService(opener: (path, {required passwordProvider}) async => throw StateError('x'));
      await expectLater(svc.open(ref), failsWith(OpenFailure.corrupted));
    });
  });

  test('static helpers', () {
    expect(PdfrxDocumentService.hasPdfHeader('%PDF-1.4'.codeUnits), isTrue);
    expect(PdfrxDocumentService.hasPdfHeader('%PDF'.codeUnits), isFalse);
    expect(PdfrxDocumentService.mapPdfiumError(3), OpenFailure.corrupted);
    expect(PdfrxDocumentService.mapPdfiumError(2), OpenFailure.notFound);
    final a = PdfrxDocumentService.computeId(10, [1, 2], [3]);
    expect(a, PdfrxDocumentService.computeId(10, [1, 2], [3]));
    expect(a, isNot(PdfrxDocumentService.computeId(11, [1, 2], [3])));
  });
}
