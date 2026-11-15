import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/platform/file_names.dart';

void main() {
  group('sanitizeDisplayName', () {
    test('keeps ordinary names', () {
      expect(sanitizeDisplayName('Report 2026.pdf'), 'Report 2026.pdf');
      expect(sanitizeDisplayName('Ünïcödé — 文書.pdf'), 'Ünïcödé — 文書.pdf');
    });

    test('strips path components (both separators)', () {
      expect(sanitizeDisplayName('../../files/settings.json'), 'settings.json');
      expect(sanitizeDisplayName(r'..\..\evil.pdf'), 'evil.pdf');
      expect(sanitizeDisplayName('/data/data/x/a.pdf'), 'a.pdf');
    });

    test('removes control, bidi and reserved characters', () {
      expect(sanitizeDisplayName('a\u0000b\nc.pdf'), 'abc.pdf');
      expect(sanitizeDisplayName('invoice\u202Efdp.exe'), 'invoicefdp.exe');
      expect(sanitizeDisplayName('a:b*c?"<>|.pdf'), 'abc.pdf');
    });

    test('no leading dots, fallback when empty', () {
      expect(sanitizeDisplayName('.hidden.pdf'), 'hidden.pdf');
      expect(sanitizeDisplayName('...'), 'document.pdf');
      expect(sanitizeDisplayName(''), 'document.pdf');
      expect(sanitizeDisplayName(null), 'document.pdf');
      expect(sanitizeDisplayName('dir/'), 'document.pdf');
    });

    test('caps length and keeps the extension', () {
      final long = '${'x' * 300}.pdf';
      final out = sanitizeDisplayName(long);
      expect(out.length, 120);
      expect(out.endsWith('.pdf'), isTrue);
    });
  });

  test('pdfFileName adds .pdf when missing', () {
    expect(pdfFileName('scan'), 'scan.pdf');
    expect(pdfFileName('scan.PDF'), 'scan.PDF');
    expect(pdfFileName('../x'), 'x.pdf');
  });
}
