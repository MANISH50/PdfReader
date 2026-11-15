import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfreader/core/security/safe_filename.dart';

String u(List<int> cps) => String.fromCharCodes(cps);

void expectSafe(String s) {
  expect(s, isNotEmpty);
  expect(s.contains('/'), isFalse, reason: s);
  expect(s.contains(r'\'), isFalse, reason: s);
  expect(s == '.' || s == '..', isFalse);
  expect(s.startsWith('.'), isFalse, reason: s);
  expect(s.startsWith('-'), isFalse, reason: s);
  expect(utf8.encode(s).length, lessThanOrEqualTo(SafeFilename.maxUtf8Bytes), reason: s);
  for (final r in s.runes) {
    expect(r >= 0x20 && r != 0x7F && !(r >= 0x80 && r <= 0x9F), isTrue, reason: 'control U+${r.toRadixString(16)}');
    expect((r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) || r == 0x200E || r == 0x200F, isFalse,
        reason: 'bidi U+${r.toRadixString(16)}');
    expect(r >= 0xD800 && r <= 0xDFFF, isFalse, reason: 'surrogate');
  }
  for (final c in '<>:"|?*'.split('')) {
    expect(s.contains(c), isFalse, reason: '$s contains $c');
  }
}

void main() {
  group('SafeFilename.sanitize', () {
    test('plain names pass through', () {
      expect(SafeFilename.sanitize('Report 2026.pdf'), 'Report 2026.pdf');
      expect(SafeFilename.sanitize('r${u([0xE9])}sum${u([0xE9])}.pdf'), 'r${u([0xE9])}sum${u([0xE9])}.pdf');
      expect(SafeFilename.sanitize(u([0x6587, 0x4EF6])), u([0x6587, 0x4EF6]));
    });

    test('path traversal and separators', () {
      for (final evil in [
        '../../etc/passwd', r'..\..\windows\system32\cmd.exe', '/absolute/path.pdf', 'a/../../b.pdf',
        '..', '.', '...', './.', '/', r'\\server\share\x.pdf', 'C:\\x.pdf', 'file:///etc/passwd',
        'a${u([0xFF0F])}b.pdf', 'a${u([0x2215])}b.pdf', '%2e%2e%2fetc',
      ]) {
        final s = SafeFilename.sanitize(evil);
        expectSafe(s);
        expect(s.contains('..${p.separator}'), isFalse);
      }
      expect(SafeFilename.sanitize('../../etc/passwd'), '_.._etc_passwd');
      expect(SafeFilename.sanitize('..'), 'document');
    });

    test('RTL override / invisible / control characters are removed', () {
      // "invoice<RLO>fdp.exe" displays as "invoiceexe.pdf"
      final rlo = 'invoice${u([0x202E])}fdp.exe';
      expect(SafeFilename.sanitize(rlo), 'invoicefdp.exe');
      expect(SafeFilename.sanitize(rlo, forceExtension: 'pdf'), 'invoicefdp.exe.pdf');
      final nasty = 'a${u([0, 1, 0x1B, 0x7F, 0x85, 0x200B, 0x200D, 0xFEFF, 0x2066, 0x2069, 0x061C, 0xAD])}b';
      expect(SafeFilename.sanitize(nasty), 'ab');
      expect(SafeFilename.sanitize('x${u([0xE0041, 0xE0042])}y'), 'xy'); // tag characters
      expect(SafeFilename.sanitize('line\nbreak\ttab.pdf'), 'linebreaktab.pdf');
    });

    test('unicode spaces collapse, edges trimmed', () {
      expect(SafeFilename.sanitize('  a${u([0x3000, 0xA0, 0x2003])}b  .pdf'), 'a b.pdf');
      expect(SafeFilename.sanitize('name.pdf. . .'), 'name.pdf');
      expect(SafeFilename.sanitize('.hidden'), 'hidden');
      expect(SafeFilename.sanitize('--rf'), 'rf');
    });

    test('lone surrogates are dropped, pairs kept', () {
      final s = SafeFilename.sanitize('a${String.fromCharCode(0xD800)}b${String.fromCharCode(0xDC00)}c${u([0x1F600])}');
      expect(s, 'abc${u([0x1F600])}');
    });

    test('Windows reserved device names', () {
      for (final n in ['CON', 'con.pdf', 'NUL', 'aux.txt', 'COM1', 'lpt9.pdf', 'PRN', 'com${u([0xB9])}']) {
        final s = SafeFilename.sanitize(n);
        expect(s.startsWith('_'), isTrue, reason: '$n -> $s');
      }
      expect(SafeFilename.sanitize('console.pdf'), 'console.pdf');
      expect(SafeFilename.sanitize('CON.tar.gz'), '_CON.tar.gz');
    });

    test('reserved punctuation replaced', () {
      expect(SafeFilename.sanitize('a<b>c:d"e|f?g*h.pdf'), 'a_b_c_d_e_f_g_h.pdf');
    });

    test('empty / null fall back', () {
      expect(SafeFilename.sanitize(null), 'document');
      expect(SafeFilename.sanitize(''), 'document');
      expect(SafeFilename.sanitize(u([0x202E, 0x200B])), 'document');
      expect(SafeFilename.sanitize('', forceExtension: 'pdf'), 'document.pdf');
      expect(SafeFilename.sanitize('', fallback: '../evil'), '_evil');
      expect(SafeFilename.sanitize('.pdf', forceExtension: 'pdf'), 'pdf.pdf');
    });

    test('forceExtension', () {
      expect(SafeFilename.sanitize('a.PDF', forceExtension: 'pdf'), 'a.pdf');
      expect(SafeFilename.sanitize('a', forceExtension: '.pdf'), 'a.pdf');
      expect(SafeFilename.sanitize('a.exe', forceExtension: 'pdf'), 'a.exe.pdf');
    });

    test('length cap respects UTF-8 bytes and keeps extension', () {
      final long = '${'x' * 1000}.pdf';
      final s = SafeFilename.sanitize(long);
      expect(s.endsWith('.pdf'), isTrue);
      expect(utf8.encode(s).length, lessThanOrEqualTo(200));
      final cjk = '${u([0x6587]) * 500}.pdf';
      final c = SafeFilename.sanitize(cjk);
      expect(c.endsWith('.pdf'), isTrue);
      expect(utf8.encode(c).length, lessThanOrEqualTo(200));
      final emoji = u([0x1F600]) * 300;
      final e = SafeFilename.sanitize(emoji);
      expectSafe(e);
      expect(e.runes.every((r) => r == 0x1F600), isTrue); // no split code points
    });

    test('huge input is fast and safe', () {
      final sw = Stopwatch()..start();
      final s = SafeFilename.sanitize('${'../' * 2000000}x.pdf');
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expectSafe(s);
    });

    test('fuzz: random code points always produce safe names', () {
      final rnd = Random(42);
      for (var i = 0; i < 3000; i++) {
        final len = rnd.nextInt(80);
        final cps = List.generate(len, (_) {
          switch (rnd.nextInt(5)) {
            case 0:
              return rnd.nextInt(0x80);
            case 1:
              return [0x2F, 0x5C, 0x2E, 0x202E, 0x200B, 0x0, 0x3A][rnd.nextInt(7)];
            case 2:
              return 0x80 + rnd.nextInt(0x800);
            case 3:
              return 0x2000 + rnd.nextInt(0x100);
            default:
              return 0x10000 + rnd.nextInt(0xFFFFF);
          }
        });
        final raw = String.fromCharCodes(cps);
        final s = SafeFilename.sanitize(raw, forceExtension: rnd.nextBool() ? 'pdf' : null);
        expectSafe(s);
        expect(SafeFilename.sanitize(s, forceExtension: s.endsWith('.pdf') ? 'pdf' : null), s,
            reason: 'idempotent for ${cps.map((c) => c.toRadixString(16))}');
      }
    });
  });

  group('SafeFilename.childPath / PathGuard', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('safe_fn'));
    tearDown(() => root.deleteSync(recursive: true));

    test('child stays inside directory', () {
      for (final evil in ['../../x.pdf', '/etc/passwd', '..', r'..\..\x', 'a/b/c']) {
        final path = SafeFilename.childPath(root, evil);
        expect(p.dirname(path), p.normalize(p.absolute(root.path)));
        expect(PathGuard.isInside(root.path, path), isTrue);
      }
    });

    test('unique names never overwrite', () {
      final a = SafeFilename.uniqueChildPath(root, 'x.pdf');
      File(a).writeAsStringSync('1');
      final b = SafeFilename.uniqueChildPath(root, 'x.pdf');
      expect(p.basename(b), 'x (2).pdf');
      File(b).writeAsStringSync('2');
      expect(p.basename(SafeFilename.uniqueChildPath(root, 'x.pdf')), 'x (3).pdf');
    });

    test('existing symlink at target is refused', () {
      final outside = Directory.systemTemp.createTempSync('outside');
      addTearDown(() => outside.deleteSync(recursive: true));
      Link(p.join(root.path, 'evil.pdf')).createSync(p.join(outside.path, 'target.pdf'));
      expect(() => SafeFilename.childPath(root, 'evil.pdf'), throwsA(isA<UnsafePathException>()));
    });

    test('PathGuard resolves symlinked directories', () {
      final outside = Directory.systemTemp.createTempSync('outside');
      addTearDown(() => outside.deleteSync(recursive: true));
      Link(p.join(root.path, 'link')).createSync(outside.path);
      expect(PathGuard.isInside(root.path, p.join(root.path, 'link', 'new.pdf')), isFalse);
      expect(PathGuard.isInside(root.path, p.join(root.path, 'link', 'new.pdf'), resolveLinks: false), isTrue);
      expect(PathGuard.isInside(root.path, p.join(root.path, '..', 'x')), isFalse);
      expect(PathGuard.isInside(root.path, root.path), isTrue);
      expect(PathGuard.isInside(root.path, '${root.path}-sibling/x'), isFalse);
    });
  });
}
