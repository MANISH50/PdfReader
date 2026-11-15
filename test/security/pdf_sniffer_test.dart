import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/security/pdf_sniffer.dart';

final _minimalPdf = ascii.encode('%PDF-1.7\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n');

void main() {
  group('PdfSniffer.findHeader / sniffBytes', () {
    test('header at start and within 1024 bytes', () {
      expect(PdfSniffer.findHeader(_minimalPdf), 0);
      final junk = Uint8List.fromList([...List.filled(1000, 0x20), ..._minimalPdf]);
      expect(PdfSniffer.findHeader(junk), 1000);
      expect(PdfSniffer.sniffBytes(junk).ok, isTrue);
    });

    test('header after 1024 bytes or truncated is rejected', () {
      final late = Uint8List.fromList([...List.filled(1020, 0x20), ..._minimalPdf]);
      expect(PdfSniffer.findHeader(late), -1);
      expect(PdfSniffer.sniffBytes(late).failure, SniffFailure.notPdf);
      expect(PdfSniffer.findHeader(ascii.encode('%PDF')), -1);
      expect(PdfSniffer.findHeader(ascii.encode('%PDF-')), 0);
      expect(PdfSniffer.findHeader(const []), -1);
    });

    test('non-PDF content rejected', () {
      for (final s in ['PK\x03\x04', '<html>', '%!PS-Adobe', '\x89PNG', '%pdf-1.4']) {
        expect(PdfSniffer.sniffBytes(Uint8List.fromList(latin1.encode(s))).failure, SniffFailure.notPdf, reason: s);
      }
      expect(PdfSniffer.sniffBytes(Uint8List(0)).failure, SniffFailure.empty);
    });

    test('size cap', () {
      final r = PdfSniffer.sniffBytes(Uint8List.fromList(_minimalPdf), maxBytes: 10);
      expect(r.failure, SniffFailure.tooLarge);
      expect(r.failure!.openFailure, OpenFailure.tooLarge);
      expect(() => r.throwIfFailed(), throwsA(isA<DocumentOpenException>()));
    });
  });

  group('PdfSniffer.sniffFile', () {
    late Directory root;
    late Directory outside;
    setUp(() {
      root = Directory.systemTemp.createTempSync('sniff_root');
      outside = Directory.systemTemp.createTempSync('sniff_out');
    });
    tearDown(() {
      root.deleteSync(recursive: true);
      outside.deleteSync(recursive: true);
    });

    String write(Directory d, String name, List<int> bytes) {
      final f = File(p.join(d.path, name))..writeAsBytesSync(bytes);
      return f.path;
    }

    test('accepts a PDF inside allowed root', () async {
      final path = write(root, 'a.pdf', _minimalPdf);
      final r = await PdfSniffer.sniffFile(path, allowedRoots: [root.path]);
      expect(r.ok, isTrue, reason: '$r');
      expect(r.sizeBytes, _minimalPdf.length);
      expect(r.resolvedPath, isNotNull);
      expect((await PdfSniffer.sniffFile(path)).ok, isTrue);
    });

    test('missing, empty, directory, not pdf, too large', () async {
      expect((await PdfSniffer.sniffFile(p.join(root.path, 'nope.pdf'))).failure, SniffFailure.notFound);
      expect((await PdfSniffer.sniffFile(write(root, 'e.pdf', const []))).failure, SniffFailure.empty);
      final dir = Directory(p.join(root.path, 'dir.pdf'))..createSync();
      expect((await PdfSniffer.sniffFile(dir.path)).failure, SniffFailure.notAFile);
      expect((await PdfSniffer.sniffFile(write(root, 'x.pdf', utf8.encode('MZ not a pdf')))).failure,
          SniffFailure.notPdf);
      expect((await PdfSniffer.sniffFile(write(root, 'big.pdf', _minimalPdf), maxBytes: 8)).failure,
          SniffFailure.tooLarge);
    });

    test('path outside allowed roots is rejected (including ../ traversal)', () async {
      final out = write(outside, 'o.pdf', _minimalPdf);
      expect((await PdfSniffer.sniffFile(out, allowedRoots: [root.path])).failure, SniffFailure.outsideAllowedDirs);
      final traversal = p.join(root.path, '..', p.basename(outside.path), 'o.pdf');
      expect((await PdfSniffer.sniffFile(traversal, allowedRoots: [root.path])).failure,
          SniffFailure.outsideAllowedDirs);
    });

    test('symlinks: allowed only when the target is inside an allowed root', () async {
      final out = write(outside, 'o.pdf', _minimalPdf);
      final evilLink = p.join(root.path, 'evil.pdf');
      Link(evilLink).createSync(out);
      expect((await PdfSniffer.sniffFile(evilLink, allowedRoots: [root.path])).failure,
          SniffFailure.outsideAllowedDirs);
      // No allowed roots: symlinks are never followed.
      expect((await PdfSniffer.sniffFile(evilLink)).failure, SniffFailure.outsideAllowedDirs);

      final inside = write(root, 'real.pdf', _minimalPdf);
      final goodLink = p.join(root.path, 'good.pdf');
      Link(goodLink).createSync(inside);
      final ok = await PdfSniffer.sniffFile(goodLink, allowedRoots: [root.path]);
      expect(ok.ok, isTrue);
      expect(p.basename(ok.resolvedPath!), 'real.pdf');

      // Link to a directory inside the root is still not a file.
      final dirLink = p.join(root.path, 'dirlink');
      Link(dirLink).createSync(root.path);
      expect((await PdfSniffer.sniffFile(dirLink, allowedRoots: [root.path])).failure, SniffFailure.notAFile);

      // Dangling link.
      final dangling = p.join(root.path, 'dangling.pdf');
      Link(dangling).createSync(p.join(root.path, 'missing.pdf'));
      expect((await PdfSniffer.sniffFile(dangling, allowedRoots: [root.path])).failure, SniffFailure.notFound);
    });

    test('device files are rejected', () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      expect((await PdfSniffer.sniffFile('/dev/zero')).failure, SniffFailure.notAFile);
      expect((await PdfSniffer.sniffFile('/dev/null')).failure, SniffFailure.notAFile);
    });
  });
}
