import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/features/export/page_range.dart';

void main() {
  List<int> ok(String s, [int n = 10]) {
    final r = PageRangeParser.parse(s, n);
    expect(r.error, isNull, reason: s);
    return r.pages;
  }

  String? err(String s, [int n = 10]) => PageRangeParser.parse(s, n).error;

  group('PageRangeParser valid', () {
    test('single, ranges and lists', () {
      expect(ok('1'), [1]);
      expect(ok('1-3,5'), [1, 2, 3, 5]);
      expect(ok(' 2 - 4 ; 7 '), [2, 3, 4, 7]);
      expect(ok('10'), [10]);
    });
    test('sorted and de-duplicated', () {
      expect(ok('5,1-3,2,5'), [1, 2, 3, 5]);
    });
    test('open-ended ranges', () {
      expect(ok('8-'), [8, 9, 10]);
      expect(ok('-2'), [1, 2]);
    });
    test('en dash, em dash and minus sign', () {
      expect(ok('1–3'), [1, 2, 3]);
      expect(ok('1—3'), [1, 2, 3]);
      expect(ok('1−3'), [1, 2, 3]);
    });
    test('tolerates empty items', () {
      expect(ok('1,,3,'), [1, 3]);
    });
    test('single-element range', () {
      expect(ok('4-4'), [4]);
    });
  });

  group('PageRangeParser invalid', () {
    test('empty', () {
      expect(err(''), isNotNull);
      expect(err('   '), isNotNull);
      expect(err(',,'), isNotNull);
    });
    test('out of range', () {
      expect(err('0'), contains('does not exist'));
      expect(err('11'), contains('does not exist'));
      expect(err('3-11'), contains('does not exist'));
      expect(err('99999999999999999999'), isNotNull);
    });
    test('reversed range', () {
      expect(err('5-3'), contains('after'));
    });
    test('garbage', () {
      expect(err('a'), isNotNull);
      expect(err('1-2-3'), isNotNull);
      expect(err('-'), isNotNull);
      expect(err('1.5'), isNotNull);
      expect(err('1 2', 20), isNotNull); // not silently read as 12
    });
    test('too long input', () {
      expect(err('1,' * 600), contains('too long'));
    });
    test('document without pages', () {
      expect(err('1', 0), isNotNull);
    });
  });

  test('format', () {
    expect(PageRangeParser.format([5, 1, 2, 3, 9, 10]), '1-3, 5, 9-10');
    expect(PageRangeParser.format([]), '');
    expect(PageRangeParser.format([4]), '4');
  });

  test('format/parse round trip', () {
    final pages = [1, 2, 4, 6, 7, 8];
    expect(ok(PageRangeParser.format(pages)), pages);
  });
}
