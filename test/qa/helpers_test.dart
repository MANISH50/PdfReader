import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/core/models/app_settings.dart';
import 'package:pdfreader/core/models/export_job.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/platform/platform_services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Scaffold;

import 'package:pdfrx/pdfrx.dart';

import '../helpers/corpus.dart';
import '../helpers/huge_pdf_writer.dart';
import '../helpers/pump_app.dart';

void main() {
  final corpus = Corpus.load();

  group('corpus manifest', () {
    test('every committed file is listed, small, and matches its sha256', () {
      final listed = {for (final e in corpus.entries) e.path};
      final onDisk = corpus.dir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.substring(corpus.dir.path.length + 1))
          .where((p) => p.endsWith('.pdf'))
          .toSet();
      expect(onDisk.difference(listed), isEmpty, reason: 'unlisted files in ${corpus.dir.path}');
      final manifest = jsonDecode(File('${corpus.dir.path}/manifest.json').readAsStringSync()) as Map;
      var total = 0;
      for (final f in (manifest['files'] as List).cast<Map<String, Object?>>()) {
        final file = File('${corpus.dir.path}/${f['path']}');
        if (!file.existsSync()) continue; // e.g. huge.pdf when not generated
        final bytes = file.readAsBytesSync();
        total += bytes.length;
        if (f['sha256'] != null) {
          expect(sha256.convert(bytes).toString(), f['sha256'], reason: '${f['path']} changed; regenerate');
        }
        if (corpus.dir.path.endsWith(Corpus.defaultDir)) {
          expect(bytes.length, lessThanOrEqualTo(310 * 1024), reason: '${f['path']} too big to commit');
        }
      }
      if (corpus.dir.path.endsWith(Corpus.defaultDir)) expect(total, lessThan(5 * 1024 * 1024));
    });

    test('covers every required category', () {
      for (final name in ['tiny.pdf', 'text_multi.pdf', 'scanned.pdf', 'password.pdf', 'owner-only-protected.pdf',
        'forms.pdf', 'rtl_arabic_hebrew.pdf', 'hindi.pdf', 'mixed_rotation.pdf', 'annotated.pdf',
        'malformed/zero_bytes.pdf', 'malformed/decompression_bomb.pdf', 'malformed/deep_nesting.pdf',
        'malformed/huge_page_count.pdf', 'malformed/huge_mediabox.pdf', 'malformed/circular_pages_tree.pdf']) {
        expect(corpus.entries.any((e) => e.path == name), isTrue, reason: name);
      }
      expect(corpus.where('fuzz').length, greaterThanOrEqualTo(200));
    });
  });

  group('FakeDocumentService', () {
    setUpAll(initPdfrxForTests);

    test('imports and opens a real PDF', () async {
      final h = TestHarness();
      addTearDown(h.dispose);
      final ref = await h.documentService.importFile(corpus.byPath('tiny.pdf').absolutePath);
      final doc = await h.documentService.open(ref);
      expect(doc.pages.length, 1);
      await doc.dispose();
      final again = await h.documentService.importFile(corpus.byPath('tiny.pdf').absolutePath);
      expect(again.id, ref.id, reason: 'stable id');
    });

    test('password flow: retry then cancel', () async {
      final h = TestHarness();
      addTearDown(h.dispose);
      final ref = await h.documentService.importFile(corpus.byPath('password.pdf').absolutePath);
      final asked = <bool>[];
      final doc = await h.documentService.open(ref, askPassword: ({required retry}) async {
        asked.add(retry);
        return retry ? 'test123' : 'nope';
      });
      expect(asked, [false, true]);
      await doc.dispose();
      await expectLater(
        h.documentService.open(ref, askPassword: ({required retry}) async => null),
        throwsA(isA<DocumentOpenException>().having((e) => e.failure, 'failure', OpenFailure.cancelled)),
      );
    });

    test('maps engine errors to DocumentOpenException', () async {
      final h = TestHarness();
      addTearDown(h.dispose);
      final ref = await h.documentService.importFile(corpus.byPath('malformed/png_renamed.pdf').absolutePath);
      await expectLater(h.documentService.open(ref), throwsA(isA<DocumentOpenException>()));
    });

    test('writeHugePdf produces a valid PDF (small run)', () async {
      final dir = Directory.systemTemp.createTempSync('huge_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = await writeHugePdf('${dir.path}/h.pdf', pages: 6, minBytes: 0, distinctImages: 2);
      final doc = await PdfDocument.openFile(f.path);
      expect(doc.pages.length, 6);
      final img = await doc.pages[5].render(width: 60, height: 83, fullWidth: 60, fullHeight: 83);
      expect(img, isNotNull);
      img!.dispose();
      expect((await doc.pages[5].loadText())!.fullText, contains('Huge page 6'));
      await doc.dispose();
    });

    test('FakeExporter writes TXT with real text', () async {
      final h = TestHarness();
      addTearDown(h.dispose);
      final ref = await h.documentService.importFile(corpus.byPath('tiny.pdf').absolutePath);
      final doc = await h.documentService.open(ref);
      final r = await h.exporter.export(doc, const ExportOptions(format: ExportFormat.txt), baseName: 'tiny');
      expect(File(r.files.single).readAsStringSync(), contains('Hello PdfReader'));
      await doc.dispose();
    });
  });

  group('pumpApp', () {
    testWidgets('lands on home with fakes wired in', (tester) async {
      final h = await pumpApp(tester);
      expect(find.text('PdfReader'), findsWidgets);
      final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
      expect(container.read(filePickServiceProvider), same(h.filePick));
      expect(container.read(documentServiceProvider), same(h.documentService));
      expect(container.read(settingsProvider).value?.onboardingDone, isTrue);
    });

    testWidgets('can start on onboarding', (tester) async {
      await pumpApp(tester, showOnboarding: true, settings: const AppSettings());
      expect(find.byType(Scaffold), findsOneWidget);
    });

    test('platform fakes record calls', () async {
      final h = TestHarness();
      addTearDown(h.dispose);
      h.filePick.pickQueue.add(['/a.pdf']);
      expect(await h.filePick.pickPdfs(), ['/a.pdf']);
      expect(await h.filePick.pickPdfs(), isEmpty);
      await h.share.shareFiles(['/x.txt'], subject: 's');
      expect(h.share.shared.single.paths, ['/x.txt']);
      h.incoming.initial = const IncomingFile(path: '/in.pdf');
      expect((await h.incoming.initialFile())?.path, '/in.pdf');
      expect(await h.incoming.initialFile(), isNull);
      final next = h.incoming.files.first;
      h.incoming.deliver(const IncomingFile(path: '/b.pdf'));
      expect((await next).path, '/b.pdf');
    });
  });
}
