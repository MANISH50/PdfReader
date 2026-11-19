import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/documents/document_kind.dart';
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/pdf/pdfrx_document_service.dart';
import 'package:pdfreader/features/reader/docx_parser.dart';
import 'package:pdfreader/features/reader/reader_model.dart';
import 'package:pdfreader/features/reader/text_markdown_parser.dart';

import 'fixtures.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('reader_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final f = File(p.join(tmp.path, name))..writeAsBytesSync(bytes);
    return f.path;
  }

  group('sniffDocumentKind', () {
    test('detects each kind', () async {
      expect(await sniffDocumentKind(write('a.bin', utf8.encode('junk\n%PDF-1.7\n...'))), DocumentKind.pdf);
      expect(await sniffDocumentKind(write('w.zip', sampleDocx())), DocumentKind.docx);
      expect(await sniffDocumentKind(write('n.md', utf8.encode('# Title\n\nHello'))), DocumentKind.markdown);
      expect(await sniffDocumentKind(write('x', utf8.encode('# Title')), displayName: 'Read me.markdown'),
          DocumentKind.markdown);
      expect(await sniffDocumentKind(write('l.log', utf8.encode('12:00 started\n12:01 ok\n'))), DocumentKind.text);
      expect(await sniffDocumentKind(write('noext', utf8.encode('{"a": 1}'))), DocumentKind.text);
      expect(await sniffDocumentKind(write('u.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode('héllo wörld')])),
          DocumentKind.text);
      final utf16 = <int>[0xFF, 0xFE];
      for (final c in 'Hello UTF-16 text\n'.codeUnits) {
        utf16..add(c & 0xFF)..add(c >> 8);
      }
      expect(await sniffDocumentKind(write('w.txt', utf16)), DocumentKind.text);
      expect(await sniffDocumentKind(write('empty.txt', [])), DocumentKind.text);
    });

    test('binary junk and non-Word zips are unsupported', () async {
      final junk = Uint8List.fromList(List.generate(4096, (i) => (i * 7919 + 13) % 256));
      expect(await sniffDocumentKind(write('junk.bin', junk)), isNull);
      expect(await sniffDocumentKind(write('nul.txt', Uint8List(2000))), isNull); // all NUL control chars
      final zip = buildZip({'other.xml': utf8.encode('<x/>')});
      expect(await sniffDocumentKind(write('fake.docx', zip)), isNull);
      expect(await sniffDocumentKind(write('macro.docm', sampleDocx())), isNull);
      expect(await sniffDocumentKind(p.join(tmp.path, 'missing')), isNull);
    });
  });

  group('DocumentRef', () {
    test('kind round-trips and missing kind means pdf (older JSON)', () {
      const d = DocumentRef(id: 'a', path: '/x.md', displayName: 'x.md', sizeBytes: 3, kind: DocumentKind.markdown);
      expect(DocumentRef.fromJson(d.toJson()).kind, DocumentKind.markdown);
      final old = DocumentRef.fromJson({'id': 'b', 'path': '/y.pdf', 'displayName': 'y.pdf', 'sizeBytes': 1});
      expect(old.kind, DocumentKind.pdf);
      expect(old.isPdf, isTrue);
      expect(DocumentRef.fromJson({...d.toJson(), 'kind': 'nonsense'}).kind, DocumentKind.pdf);
    });
  });

  group('importFile', () {
    final service = PdfrxDocumentService();

    test('imports text, markdown and docx with their kind and a stable id', () async {
      final t = await service.importFile(write('in_1.pdf', utf8.encode('hello')), displayName: 'notes.txt');
      expect(t.kind, DocumentKind.text);
      final t2 = await service.importFile(write('in_2.txt', utf8.encode('hello')), displayName: 'copy.txt');
      expect(t2.id, t.id);
      final m = await service.importFile(write('r.md', utf8.encode('# Hi')));
      expect(m.kind, DocumentKind.markdown);
      final d = await service.importFile(write('in_3.bin', sampleDocx()), displayName: 'Report.docx');
      expect(d.kind, DocumentKind.docx);
      expect(d.displayName, 'Report.docx');
    });

    test('a .pdf without a PDF header is still notPdf; junk is unsupported', () async {
      await expectLater(service.importFile(write('fake.pdf', utf8.encode('plain text'))),
          throwsA(isA<DocumentOpenException>().having((e) => e.failure, 'failure', OpenFailure.notPdf)));
      await expectLater(service.importFile(write('junk.bin', Uint8List.fromList(List.generate(999, (i) => i % 256)))),
          throwsA(isA<DocumentOpenException>().having((e) => e.failure, 'failure', OpenFailure.unsupported)));
    });

    test('text over 20 MB is too large', () async {
      final f = File(p.join(tmp.path, 'big.log'));
      final raf = f.openSync(mode: FileMode.write);
      final line = Uint8List.fromList(utf8.encode('${'x' * 1023}\n'));
      for (var i = 0; i < 20 * 1024 + 1; i++) {
        raf.writeFromSync(line);
      }
      raf.closeSync();
      await expectLater(service.importFile(f.path),
          throwsA(isA<DocumentOpenException>().having((e) => e.failure, 'failure', OpenFailure.tooLarge)));
    });
  });

  group('plain text', () {
    test('code-like files become lines; very long lines are split', () {
      final doc = parsePlainText('a\nb\r\n${'y' * 4500}\n', monospace: true);
      final lines = doc.blocks.cast<LineBlock>().map((b) => b.text).toList();
      expect(lines.take(2), ['a', 'b']);
      expect(lines.skip(2).map((l) => l.length), [2000, 2000, 500]);
      expect(doc.monospace, isTrue);
    });

    test('prose is grouped into paragraphs', () {
      final doc = parsePlainText('one\ntwo\n\nthree', monospace: false);
      final blocks = doc.blocks.cast<LineBlock>();
      expect(blocks.map((b) => b.text), ['one\ntwo', 'three']);
      expect(blocks.last.gapBefore, isTrue);
    });

    test('code-like extensions', () {
      expect(isCodeLikeName('a.json'), isTrue);
      expect(isCodeLikeName('server.LOG'), isTrue);
      expect(isCodeLikeName('notes.txt'), isFalse);
    });
  });

  group('markdown', () {
    test('AST becomes headings, lists, tables, code, quotes and rules', () {
      final doc = parseMarkdown('''
# Title

Some **bold**, *italic*, ~~gone~~ and `code` with [a link](https://example.com).

- one
- two
  1. nested

3. three
4. four

- [x] done
- [ ] todo

> quoted

```dart
void main() {}
```

| A | B |
|---|---|
| 1 | 2 |

---

![remote](https://tracker.example/pixel.png) <b>raw</b>
''');
      final b = doc.blocks;
      final h = b.first as TextBlock;
      expect(h.headingLevel, 1);
      expect(h.searchText, 'Title');

      final para = b[1] as TextBlock;
      expect(para.spans.firstWhere((s) => s.text == 'bold').bold, isTrue);
      expect(para.spans.firstWhere((s) => s.text == 'italic').italic, isTrue);
      expect(para.spans.firstWhere((s) => s.text == 'gone').strike, isTrue);
      expect(para.spans.firstWhere((s) => s.text == 'code').code, isTrue);
      expect(para.spans.firstWhere((s) => s.text == 'a link').link, 'https://example.com');

      final items = b.whereType<TextBlock>().where((t) => t.marker != null).toList();
      expect(items.map((t) => t.marker), ['•', '•', '1.', '3.', '4.', '☑', '☐']);
      expect(items[2].indent, 1);
      expect(items[5].searchText, 'done');

      expect(b.whereType<TextBlock>().firstWhere((t) => t.searchText == 'quoted').quoteDepth, 1);
      final code = b.whereType<CodeBlock>().single;
      expect(code.text, 'void main() {}');
      expect(code.language, 'dart');
      final table = b.whereType<TableBlock>().single;
      expect(table.headerRows, 1);
      expect(table.rows.length, 2);
      expect(spansText(table.rows[1][1].single), '2');
      expect(table.rows[0][0].single.first.bold, isTrue);
      expect(b.whereType<RuleBlock>(), hasLength(1));

      final last = b.last as TextBlock;
      expect(last.spans.first.imageAlt, 'remote'); // placeholder, never loaded
      expect(last.searchText, contains('<b>raw</b>')); // raw HTML shown as text
    });

    test('heading slugs', () {
      expect(headingSlug('Getting Started!'), 'getting-started');
      expect(headingSlug('Über  uns'), 'über-uns');
    });
  });

  group('docx', () {
    test('parses paragraphs, headings, runs, lists, tables, links, images, page breaks', () {
      final doc = parseDocx(sampleDocx());
      expect(doc.notice, docxNotice);
      final b = doc.blocks;
      final h = b.whereType<TextBlock>().first;
      expect(h.headingLevel, 1);
      expect(h.searchText, 'Quarterly report');

      final runs = b.whereType<TextBlock>().firstWhere((t) => t.searchText.startsWith('Plain'));
      expect(runs.searchText, 'Plain and bold italic notbold');
      expect(runs.spans.firstWhere((s) => s.text == 'bold').bold, isTrue);
      final it = runs.spans.firstWhere((s) => s.text == ' italic');
      expect(it.italic && it.underline, isTrue);
      expect(runs.spans.firstWhere((s) => s.text == ' notbold').bold, isFalse);

      final items = b.whereType<TextBlock>().where((t) => t.marker != null).toList();
      expect(items.map((t) => '${t.marker} ${t.searchText}'), ['• First bullet', '1. Step one', '2. Step two']);

      final table = b.whereType<TableBlock>().single;
      expect(table.rows.map((r) => r.map((c) => spansText(c.single)).toList()).toList(), [
        ['Name', 'Value'],
        ['Alpha', '42'],
      ]);

      final link = b.whereType<TextBlock>().firstWhere((t) => t.searchText == 'Visit our site');
      expect(link.spans.last.link, 'https://example.com/page');

      final image = b.whereType<ImageBlock>().single;
      expect(image.bytes, isNotNull);
      expect(image.alt, 'Chart');
      expect((image.width, image.height), (4, 3));

      final breakAt = b.indexWhere((x) => x is PageBreakBlock);
      expect(breakAt, greaterThan(0));
      expect(b.skip(breakAt).whereType<TextBlock>().any((t) => t.searchText == 'After the break'), isTrue);
    });

    test('DOCTYPE entities are never expanded', () {
      final xml = sampleDocumentXml().replaceFirst('<w:document',
          '<!DOCTYPE w:document [<!ENTITY boom "BOOMBOOMBOOM"><!ENTITY ext SYSTEM "file:///etc/passwd">]>\n<w:document');
      final withRef = xml.replaceFirst('After the break', 'After &boom; &ext;');
      final doc = parseDocx(sampleDocx(documentXml: withRef));
      final all = doc.blocks.map((b) => b.searchText).join('\n');
      expect(all, isNot(contains('BOOMBOOMBOOM')));
      expect(all, isNot(contains('root:')));
    });

    Matcher fails(ReaderFailure f) => throwsA(isA<ReaderOpenException>().having((e) => e.failure, 'failure', f));

    test('zip bomb: declared size over the cap is refused', () {
      final big = sampleDocumentXml(extraBody: '<w:p><w:r><w:t>${' ' * 300000}</w:t></w:r></w:p>');
      expect(() => parseDocx(sampleDocx(documentXml: big), limits: const DocxLimits(maxXmlBytes: 100000)),
          fails(ReaderFailure.unsafe));
    });

    test('zip bomb: a lying size is caught while inflating', () {
      final big = sampleDocumentXml(extraBody: '<w:p><w:r><w:t>${' ' * 300000}</w:t></w:r></w:p>');
      final lying = lieAboutSize(sampleDocx(documentXml: big), 'word/document.xml', 1000);
      expect(() => parseDocx(lying, limits: const DocxLimits(maxXmlBytes: 100000)), fails(ReaderFailure.unsafe));
    });

    test('too many entries is refused', () {
      final extra = {for (var i = 0; i < 2001; i++) 'word/junk$i.xml': utf8.encode('<x/>')};
      expect(() => parseDocx(sampleDocx(extra: extra)), fails(ReaderFailure.unsafe));
    });

    test('path traversal and absolute entry names are refused', () {
      expect(() => parseDocx(sampleDocx(extra: {'../../evil.sh': utf8.encode('x')})), fails(ReaderFailure.unsafe));
      expect(() => parseDocx(sampleDocx(extra: {'/etc/evil': utf8.encode('x')})), fails(ReaderFailure.unsafe));
    });

    test('garbage and missing document.xml are damaged', () {
      expect(() => parseDocx(Uint8List.fromList(utf8.encode('PK\x03\x04 nope'))), fails(ReaderFailure.damaged));
      expect(() => parseDocx(buildZip({'a.xml': utf8.encode('<a/>')})), fails(ReaderFailure.damaged));
    });

    test('time budget gives a friendly timeout', () {
      expect(() => parseDocx(sampleDocx(), budget: ParseBudget(Duration.zero)), fails(ReaderFailure.timeout));
    });

    test('image size header parsing', () {
      expect(imageSize(tinyPng()), (w: 4, h: 3));
      expect(imageSize(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}
