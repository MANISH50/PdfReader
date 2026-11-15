import 'dart:math' as math;
import 'dart:ui';

import '../../core/models/reading_state.dart';
import '../../core/security/limits.dart';

/// Pure page-layout and fit math used by the viewer. Kept free of pdfrx
/// types so it can be unit-tested without the engine.

class PagesLayout {
  const PagesLayout(this.pageRects, this.documentSize);
  final List<Rect> pageRects;
  final Size documentSize;
}

/// Continuous vertical scroll: pages stacked and horizontally centred.
PagesLayout layoutVertical(List<Size> pages, double margin) {
  final width = pages.fold(0.0, (w, p) => math.max(w, p.width)) + margin * 2;
  final rects = <Rect>[];
  var y = margin;
  for (final p in pages) {
    rects.add(Rect.fromLTWH((width - p.width) / 2, y, p.width, p.height));
    y += p.height + margin;
  }
  return PagesLayout(rects, Size(width, y));
}

/// Single page (horizontal paging): each page centred in an equal-size slot
/// so that "fit page" shows exactly one page.
PagesLayout layoutHorizontal(List<Size> pages, double margin) {
  final slotW = pages.fold(0.0, (w, p) => math.max(w, p.width));
  final slotH = pages.fold(0.0, (h, p) => math.max(h, p.height));
  final rects = <Rect>[];
  var x = margin;
  for (final p in pages) {
    rects.add(Rect.fromLTWH(x + (slotW - p.width) / 2, margin + (slotH - p.height) / 2, p.width, p.height));
    x += slotW + margin;
  }
  return PagesLayout(rects, Size(x, slotH + margin * 2));
}

/// Index of the first page of each spread. With [coverAlone] page 1 is shown
/// on its own (book style), then 2-3, 4-5, …
List<List<int>> spreadGroups(int pageCount, {bool coverAlone = true}) {
  final groups = <List<int>>[];
  var i = 0;
  if (coverAlone && pageCount > 0) {
    groups.add([0]);
    i = 1;
  }
  for (; i < pageCount; i += 2) {
    groups.add([i, if (i + 1 < pageCount) i + 1]);
  }
  return groups;
}

/// Two-page spread, spreads stacked vertically.
PagesLayout layoutSpreads(List<Size> pages, double margin, {bool coverAlone = true}) {
  final groups = spreadGroups(pages.length, coverAlone: coverAlone);
  double spreadWidth(List<int> g) =>
      g.fold(0.0, (w, i) => w + pages[i].width) + margin * (g.length - 1);
  final width = groups.fold(0.0, (w, g) => math.max(w, spreadWidth(g))) + margin * 2;
  final rects = List<Rect>.filled(pages.length, Rect.zero);
  var y = margin;
  for (final g in groups) {
    final h = g.fold(0.0, (m, i) => math.max(m, pages[i].height));
    var x = (width - spreadWidth(g)) / 2;
    for (final i in g) {
      rects[i] = Rect.fromLTWH(x, y + (h - pages[i].height) / 2, pages[i].width, pages[i].height);
      x += pages[i].width + margin;
    }
    y += h + margin;
  }
  return PagesLayout(rects, Size(width, y));
}

PagesLayout layoutFor(ReadingMode mode, List<Size> pages, double margin) => switch (mode) {
      ReadingMode.singlePage => layoutHorizontal(pages, margin),
      ReadingMode.twoPage => layoutSpreads(pages, margin),
      _ => layoutVertical(pages, margin),
    };

/// The rect that "fit" should frame for [pageIndex]: the page itself, or its
/// whole spread in two-page mode.
Rect fitTargetRect(ReadingMode mode, List<Rect> rects, int pageIndex) {
  if (mode != ReadingMode.twoPage) return rects[pageIndex];
  for (final g in spreadGroups(rects.length)) {
    if (g.contains(pageIndex)) return g.map((i) => rects[i]).reduce((a, b) => a.expandToInclude(b));
  }
  return rects[pageIndex];
}

/// Zoom and centre position (document coordinates) for a fit mode.
({double zoom, Offset center}) fitFor(FitMode fit, Size view, Rect target, double margin) {
  final w = target.width + margin * 2;
  final h = target.height + margin * 2;
  if (fit == FitMode.page) {
    final zoom = math.min(view.width / w, view.height / h);
    return (zoom: zoom, center: target.center);
  }
  final zoom = view.width / w;
  // Align the top of the target with the top of the view.
  final cy = target.top - margin + view.height / 2 / zoom;
  return (zoom: zoom, center: Offset(target.center.dx, cy));
}

/// Which page to snap to in single-page mode at the end of a swipe.
int snapTargetPage({required int current, required int pageCount, required double velocityX}) {
  const threshold = 300.0;
  var target = current;
  if (velocityX < -threshold) target = current + 1;
  if (velocityX > threshold) target = current - 1;
  return target.clamp(1, pageCount);
}

/// Caps a page render scale so a single bitmap never exceeds
/// [SecurityLimits.maxRenderPixels].
double capRenderScale(double pageWidthPt, double pageHeightPt, double scale) {
  final w = pageWidthPt.clamp(1.0, SecurityLimits.maxPageSidePt);
  final h = pageHeightPt.clamp(1.0, SecurityLimits.maxPageSidePt);
  final px = w * h * scale * scale;
  if (px <= SecurityLimits.maxRenderPixels) return scale;
  return math.sqrt(SecurityLimits.maxRenderPixels / (w * h));
}

/// Suggest two-page spreads on tablets and landscape screens.
bool shouldSuggestSpread(Size screen) {
  final shortest = screen.shortestSide;
  final landscape = screen.width > screen.height;
  return shortest >= 600 || (landscape && shortest >= 480);
}
