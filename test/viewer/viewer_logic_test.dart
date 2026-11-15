import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/core/models/reading_state.dart';
import 'package:pdfreader/core/security/limits.dart';
import 'package:pdfreader/features/viewer/reflow_view.dart';
import 'package:pdfreader/features/viewer/viewer_dialogs.dart';
import 'package:pdfreader/features/viewer/viewer_layouts.dart';
import 'package:pdfreader/features/viewer/viewer_session.dart';

void main() {
  const a4 = Size(595, 842);
  const land = Size(842, 595);

  group('layouts', () {
    test('vertical stacks pages centred', () {
      final l = layoutVertical([a4, land], 8);
      expect(l.documentSize.width, 842 + 16);
      expect(l.pageRects[0].top, 8);
      expect(l.pageRects[1].top, 8 + 842 + 8);
      expect(l.pageRects[0].center.dx, closeTo(l.documentSize.width / 2, 1e-9));
    });

    test('horizontal puts each page in an equal slot', () {
      final l = layoutHorizontal([a4, land, a4], 8);
      expect(l.pageRects.map((r) => r.top < r.bottom), everyElement(isTrue));
      expect(l.pageRects[1].left, greaterThan(l.pageRects[0].right));
      expect(l.pageRects[0].center.dy, closeTo(l.pageRects[1].center.dy, 1e-9));
    });

    test('spreads: cover alone then pairs', () {
      expect(spreadGroups(5), [
        [0],
        [1, 2],
        [3, 4]
      ]);
      expect(spreadGroups(4), [
        [0],
        [1, 2],
        [3]
      ]);
      final l = layoutSpreads([a4, a4, a4], 8);
      expect(l.pageRects[1].top, l.pageRects[2].top);
      expect(l.pageRects[2].left, greaterThan(l.pageRects[1].right));
      final t = fitTargetRect(ReadingMode.twoPage, l.pageRects, 2);
      expect(t, l.pageRects[1].expandToInclude(l.pageRects[2]));
    });

    test('fit width and fit page', () {
      const view = Size(400, 800);
      const target = Rect.fromLTWH(0, 100, 600, 800);
      final w = fitFor(FitMode.width, view, target, 0);
      expect(w.zoom, closeTo(400 / 600, 1e-9));
      final p = fitFor(FitMode.page, view, target, 0);
      expect(p.zoom, closeTo(400 / 600, 1e-9));
      final p2 = fitFor(FitMode.page, const Size(800, 400), target, 0);
      expect(p2.zoom, closeTo(400 / 800, 1e-9));
      expect(p2.center, target.center);
    });

    test('snap target respects velocity and bounds', () {
      expect(snapTargetPage(current: 3, pageCount: 5, velocityX: -1000), 4);
      expect(snapTargetPage(current: 3, pageCount: 5, velocityX: 1000), 2);
      expect(snapTargetPage(current: 5, pageCount: 5, velocityX: -1000), 5);
      expect(snapTargetPage(current: 1, pageCount: 5, velocityX: 1000), 1);
      expect(snapTargetPage(current: 2, pageCount: 5, velocityX: 10), 2);
    });

    test('render scale capped by maxRenderPixels', () {
      expect(capRenderScale(595, 842, 2), 2);
      final s = capRenderScale(14400, 14400, 10);
      expect(14400 * 14400 * s * s, lessThanOrEqualTo(SecurityLimits.maxRenderPixels * 1.0001));
      // Keeps pdfrx's default preview cap (longest side <= 2000 px).
      expect(capRenderScale(3000, 1000, 1) * 3000, closeTo(2000, 1e-6));
    });

    test('huge MediaBox (> 14400 pt) uses the real size: bitmap stays bounded', () {
      for (final (w, h) in [(1e6, 1e6), (1e6, 10.0), (20000.0, 30000.0)]) {
        final s = capRenderScale(w, h, 2);
        expect(w * s * h * s, lessThanOrEqualTo(SecurityLimits.maxRenderPixels * 1.0001));
        expect(w * s, lessThanOrEqualTo(2000.0001));
        expect(h * s, lessThanOrEqualTo(2000.0001));
      }
      expect(capRenderScale(double.nan, 100, 2), lessThan(1));
      expect(capRenderScale(0, 100, 2), lessThan(1));
      expect(capRenderScale(100, double.infinity, 2), lessThan(1));
    });

    test('spread suggestion on tablets / landscape only', () {
      expect(shouldSuggestSpread(const Size(390, 844)), isFalse);
      expect(shouldSuggestSpread(const Size(844, 390)), isFalse);
      expect(shouldSuggestSpread(const Size(1024, 768)), isTrue);
      expect(shouldSuggestSpread(const Size(900, 600)), isTrue);
    });
  });

  test('parsePageInput', () {
    expect(parsePageInput('3', 10), 3);
    expect(parsePageInput(' 10 ', 10), 10);
    expect(parsePageInput('0', 10), isNull);
    expect(parsePageInput('11', 10), isNull);
    expect(parsePageInput('abc', 10), isNull);
  });

  group('reflowParagraphs', () {
    test('joins wrapped lines and de-hyphenates', () {
      const text = 'The quick brown fox jumps over the lazy dog and keeps on run-\n'
          'ning through the forest until it reaches the river bank where\n'
          'it stops.\n'
          '\n'
          'A second paragraph starts here and continues for a while longer\n'
          'to the end.';
      final p = reflowParagraphs(text);
      expect(p, hasLength(2));
      expect(p[0], contains('running through'));
      expect(p[0], endsWith('it stops.'));
      expect(p[1], startsWith('A second paragraph'));
    });

    test('empty text gives no paragraphs', () {
      expect(reflowParagraphs('  \n \n'), isEmpty);
    });
  });

  group('ViewerSession', () {
    test('clamps page, drops stale bookmarks, debounces saves', () {
      fakeAsync((async) {
        final saved = <ReadingState>[];
        final s = ViewerSession(
          initial: const ReadingState(pageNumber: 50, bookmarks: {2, 99}),
          persist: (st) async => saved.add(st),
        );
        s.attach(10);
        expect(s.page, 10);
        expect(s.bookmarks, {2});
        s.setPage(3);
        s.setPage(4);
        s.setPage(5);
        async.elapse(const Duration(milliseconds: 100));
        expect(saved, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(saved, hasLength(1));
        expect(saved.single.pageNumber, 5);
        s.toggleBookmark();
        async.flushMicrotasks();
        expect(saved.last.bookmarks, {2, 5});
        expect(s.isBookmarked, isTrue);
        s.toggleBookmark(5);
        async.flushMicrotasks();
        expect(saved.last.bookmarks, {2});
        s.setPage(7);
        s.dispose(); // flushes immediately
        async.flushMicrotasks();
        expect(saved.last.pageNumber, 7);
      });
    });

    test('zoom becomes custom only when it differs from the fit zoom', () {
      fakeAsync((async) {
        final s = ViewerSession(initial: const ReadingState(), persist: (_) async {})..attach(3);
        s.setZoom(1.0, fitZoom: 1.005);
        expect(s.fit, FitMode.width);
        s.setZoom(2.0, fitZoom: 1.0);
        expect(s.fit, FitMode.custom);
        expect(s.state.zoom, 2.0);
        s.setMode(ReadingMode.twoPage);
        expect(s.mode, ReadingMode.twoPage);
        s.toggleChrome();
        expect(s.chromeVisible, isFalse);
        s.dispose();
        async.flushMicrotasks();
      });
    });

    test('persist errors are swallowed', () {
      fakeAsync((async) {
        final s = ViewerSession(initial: const ReadingState(), persist: (_) async => throw Exception('disk'))
          ..attach(3)
          ..setPage(2);
        async.elapse(const Duration(seconds: 2));
        s.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
