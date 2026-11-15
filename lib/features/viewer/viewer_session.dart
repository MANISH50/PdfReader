import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/reading_state.dart';

/// Engine-free reading state for one open document: current page, mode, fit,
/// zoom, bookmarks and chrome visibility. Persists through [persist] with a
/// debounce on frequent changes (page/zoom) and immediately on [flush].
class ViewerSession extends ChangeNotifier {
  ViewerSession({
    required ReadingState initial,
    required this.persist,
    this.debounce = const Duration(milliseconds: 800),
  }) : _state = initial;

  final Future<void> Function(ReadingState state) persist;
  final Duration debounce;

  ReadingState _state;
  ReadingState get state => _state;

  int _pageCount = 0;
  int get pageCount => _pageCount;

  bool _chromeVisible = true;
  bool get chromeVisible => _chromeVisible;

  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;

  int get page => _state.pageNumber;
  ReadingMode get mode => _state.mode;
  FitMode get fit => _state.fitMode;
  Set<int> get bookmarks => _state.bookmarks;
  bool get isBookmarked => _state.bookmarks.contains(page);

  /// Called once the document is open; clamps the restored page and drops
  /// bookmarks that point past the end (file changed).
  void attach(int pageCount) {
    _pageCount = pageCount;
    final clamped = _state.pageNumber.clamp(1, pageCount < 1 ? 1 : pageCount);
    final marks = {for (final b in _state.bookmarks) if (b >= 1 && b <= pageCount) b};
    _state = _state.copyWith(pageNumber: clamped, bookmarks: marks, lastOpened: DateTime.now());
    _dirty = true;
    _schedule();
    notifyListeners();
  }

  void setPage(int page) {
    if (_pageCount > 0) page = page.clamp(1, _pageCount);
    if (page == _state.pageNumber) return;
    _state = _state.copyWith(pageNumber: page);
    _changed();
  }

  void setMode(ReadingMode mode) {
    if (mode == _state.mode) return;
    _state = _state.copyWith(mode: mode);
    _changed(immediate: true);
  }

  void setFit(FitMode fit) {
    if (fit == _state.fitMode) return;
    _state = _state.copyWith(fitMode: fit);
    _changed();
  }

  /// Records a user zoom. Switches to [FitMode.custom] when it differs from
  /// the current fit zoom by more than 2 %.
  void setZoom(double zoom, {double? fitZoom}) {
    if (!zoom.isFinite || zoom <= 0) return;
    final custom = fitZoom == null || (zoom / fitZoom - 1).abs() > 0.02;
    final nextFit = custom ? FitMode.custom : _state.fitMode;
    if (_state.zoom != null && (_state.zoom! - zoom).abs() < 1e-3 && nextFit == _state.fitMode) return;
    _state = ReadingState(
      pageNumber: _state.pageNumber,
      zoom: zoom,
      fitMode: nextFit,
      mode: _state.mode,
      bookmarks: _state.bookmarks,
      lastOpened: _state.lastOpened,
    );
    _changed();
  }

  void toggleBookmark([int? pageNumber]) {
    final p = pageNumber ?? page;
    final marks = {..._state.bookmarks};
    if (!marks.remove(p)) marks.add(p);
    _state = _state.copyWith(bookmarks: marks);
    _changed(immediate: true);
  }

  void toggleChrome() => setChromeVisible(!_chromeVisible);

  void setChromeVisible(bool v) {
    if (v == _chromeVisible) return;
    _chromeVisible = v;
    notifyListeners();
  }

  void _changed({bool immediate = false}) {
    _dirty = true;
    if (immediate) {
      unawaited(flush());
    } else {
      _schedule();
    }
    notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Writes pending state now. Safe to call repeatedly; errors are swallowed
  /// (losing a reading position must never crash the reader).
  Future<void> flush() async {
    _timer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    try {
      await persist(_state);
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(flush());
    super.dispose();
  }
}
