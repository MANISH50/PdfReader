// ViewerScreen — the reading experience, built on pdfrx's PdfViewer.
//
// EXTENSION POINTS (for the Editing agent and others) — see viewer_hooks.dart
// -------------------------------------------------------------------------
// * Per-page overlays: `ViewerExtensions.pageOverlays` is a list of
//   `ViewerOverlayBuilder`s: `Widget? Function(BuildContext, ViewerContext,
//   ViewerPageInfo)`. Each returned widget is stacked over one page
//   (Positioned.fill over the page as drawn, so local (0,0) = page top-left).
//   `ViewerPageInfo` gives the page→screen transform from pdfrx:
//   `pdfToLocal(Offset)`, `localToPdf(Offset)`, `pdfRectToLocal(Rect)`,
//   `localRectToPdf(Rect)` and `scale` (px per PDF point). PDF coordinates are
//   points, origin bottom-left, unrotated page (the `Annotation` convention).
//   Overlays are rebuilt as the user pans/zooms; keep them light.
// * Edit mode: when `ViewerExtensions.onEdit` is set an "Edit" button appears.
//   It toggles `ViewerContext.editMode` (ValueNotifier<bool>) and calls
//   onEdit. While editing, `editToolbarBuilder` replaces the bottom bar.
// * Toolbar actions: built-in "Organize pages" (route /organize), "Export"
//   (route /export) and "Share" (ShareService) are in the overflow menu;
//   `ViewerExtensions.extraActions` are appended there.
// * Wiring: provide a `ViewerExtensions` either through the constructor
//   (`ViewerScreen(document:, extensions:)`) or by overriding
//   `viewerExtensionsProvider` (ProviderScope override, or changing that one
//   provider line in viewer_hooks.dart). The constructor value wins.
// * `ViewerContext.controller` is the live PdfViewerController (null in
//   reflow mode); use it for goToPage, documentToLocal, etc.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app_router.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/document_ref.dart';
import '../../core/models/reading_state.dart';
import '../../core/pdf/document_service.dart';
import '../../core/providers.dart';
import '../../core/security/link_policy.dart';
import '../../ui/design_system/reading_theme.dart';
import '../../ui/design_system/tokens.dart';
import 'reflow_view.dart';
import 'viewer_dialogs.dart';
import 'viewer_hooks.dart';
import 'viewer_layouts.dart';
import 'viewer_panels.dart';
import 'viewer_session.dart';

Future<bool> _launchExternal(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({super.key, required this.document, this.extensions, this.urlOpener});

  final DocumentRef document;

  /// Plug-ins; defaults to [viewerExtensionsProvider].
  final ViewerExtensions? extensions;

  /// Opens confirmed external links; defaults to url_launcher.
  final UrlOpener? urlOpener;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

enum _Phase { loading, ready, error }

class _ViewerScreenState extends ConsumerState<ViewerScreen> with WidgetsBindingObserver {
  static const double _margin = 8;

  _Phase _phase = _Phase.loading;
  OpenFailure? _failure;
  PdfDocument? _pdf;
  PdfDocumentRef? _ref;
  ViewerSession? _session;
  bool _disposed = false;

  PdfViewerController? _controller;
  PdfTextSearcher? _searcher;
  int _viewerGen = 0;

  final _currentPage = ValueNotifier<int>(1);
  final _editMode = ValueNotifier<bool>(false);
  final _reflowKey = GlobalKey<ReflowViewState>();
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  double? _scrubValue;
  int _swipeStartPage = 1;
  bool _spreadSuggested = false;
  bool? _wakelockOn;
  bool _immersive = false;

  ViewerExtensions get _ext => widget.extensions ?? ref.read(viewerExtensionsProvider);
  ViewerSession get _s => _session!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame so the password dialog can be shown at once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  // ---------------------------------------------------------------- opening

  Future<void> _open() async {
    setState(() {
      _phase = _Phase.loading;
      _failure = null;
    });
    final doc = widget.document;
    PdfDocument pdf;
    try {
      pdf = await ref.read(documentServiceProvider).open(
            doc,
            askPassword: ({required bool retry}) async {
              if (!mounted) return null;
              return showPasswordDialog(context, retry: retry, fileName: doc.displayName);
            },
          );
    } on DocumentOpenException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _failure = e.failure;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _failure = OpenFailure.corrupted;
        });
      }
      return;
    }
    if (_disposed) {
      unawaited(pdf.dispose());
      return;
    }

    ReadingState initial;
    try {
      initial = await ref.read(readingStateStoreProvider).load(doc.id);
    } catch (_) {
      initial = const ReadingState();
    }
    if (_disposed) {
      unawaited(pdf.dispose());
      return;
    }
    final store = ref.read(readingStateStoreProvider);
    final session = ViewerSession(initial: initial, persist: (st) => store.save(doc.id, st))
      ..attach(pdf.pages.length)
      ..addListener(_onSessionChanged);
    unawaited(() async {
      try {
        await ref.read(recentFilesStoreProvider).touch(doc);
      } catch (_) {}
    }());

    _pdf = pdf;
    // The viewer never owns the document (autoDispose: false): it is shared
    // across viewer rebuilds when the reading mode changes and disposed here.
    _ref = PdfDocumentRefDirect(
      pdf,
      autoDispose: false,
      key: PdfDocumentRefKey('pdfreader-viewer:${doc.id}', [identityHashCode(pdf)]),
    );
    _session = session;
    _currentPage.value = session.page;
    _newBinding();
    setState(() => _phase = _Phase.ready);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSuggestSpread());
  }

  void _newBinding() {
    _searcher?.removeListener(_onSearchChanged);
    _searcher?.dispose();
    _controller = PdfViewerController();
    _searcher = PdfTextSearcher(_controller!)..addListener(_onSearchChanged);
    _viewerGen++;
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
    _setImmersive(!_s.chromeVisible);
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      unawaited(_session?.flush());
    }
    if (state == AppLifecycleState.paused) {
      try {
        if (_controller?.isReady ?? false) _controller!.releaseCachedImages();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _searcher?.removeListener(_onSearchChanged);
    _searcher?.dispose();
    _session?.removeListener(_onSessionChanged);
    _session?.dispose(); // flushes reading state
    _setWakelock(false);
    if (_immersive) {
      unawaited(_safeSystemUi(SystemUiMode.edgeToEdge));
    }
    final pdf = _pdf;
    if (pdf != null) {
      // Let the PdfViewer detach first.
      unawaited(Future<void>.delayed(Duration.zero, () async {
        try {
          await pdf.dispose();
        } catch (_) {}
      }));
    }
    _searchCtl.dispose();
    _searchFocus.dispose();
    _currentPage.dispose();
    _editMode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- platform

  void _setWakelock(bool on) {
    if (_wakelockOn == on) return;
    _wakelockOn = on;
    unawaited(() async {
      try {
        await (on ? WakelockPlus.enable() : WakelockPlus.disable());
      } catch (_) {}
    }());
  }

  void _setImmersive(bool on) {
    if (_immersive == on) return;
    _immersive = on;
    unawaited(_safeSystemUi(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge));
  }

  static Future<void> _safeSystemUi(SystemUiMode mode) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(mode);
    } catch (_) {}
  }

  // ------------------------------------------------------------ navigation

  bool get _pdfMode => _s.mode != ReadingMode.reflow;
  PdfViewerController? get _readyController =>
      (_controller?.isReady ?? false) && _pdfMode ? _controller : null;

  ViewerContext get _viewerContext => ViewerContext(
        document: widget.document,
        pdf: _pdf!,
        controller: _pdfMode ? _controller : null,
        currentPage: _currentPage,
        editMode: _editMode,
      );

  void _goToPage(int page) {
    page = page.clamp(1, _s.pageCount);
    _s.setPage(page);
    _currentPage.value = page;
    if (!_pdfMode) {
      _reflowKey.currentState?.jumpToPage(page);
      return;
    }
    final c = _readyController;
    if (c == null) return;
    if (_s.mode == ReadingMode.continuous) {
      unawaited(c.goToPage(pageNumber: page, anchor: PdfPageAnchor.top));
    } else {
      _applyFit(_s.fit == FitMode.custom ? FitMode.page : _s.fit, page: page);
    }
  }

  /// Zoom/position so that [fit] holds for [page] (or the current page).
  void _applyFit(FitMode fit, {int? page, Duration duration = const Duration(milliseconds: 200)}) {
    final c = _readyController;
    if (c == null) return;
    try {
      final p = (page ?? _s.page).clamp(1, c.pageCount);
      final target = fitTargetRect(_s.mode, c.layout.pageLayouts, p - 1);
      final ({double zoom, Offset center}) r;
      if (fit == FitMode.custom) {
        final z = _s.state.zoom ?? fitFor(FitMode.width, c.viewSize, target, _margin).zoom;
        r = (zoom: z, center: Offset(target.center.dx, target.top - _margin + c.viewSize.height / 2 / z));
      } else {
        r = fitFor(fit, c.viewSize, target, _margin);
      }
      final zoom = r.zoom.clamp(c.minScale, c.maxScale);
      unawaited(c.goTo(c.calcMatrixFor(r.center, zoom: zoom), duration: duration));
    } catch (_) {
      // Layout not ready yet; ignore.
    }
  }

  double? _fitZoom(FitMode fit) {
    final c = _readyController;
    if (c == null) return null;
    try {
      final target = fitTargetRect(_s.mode, c.layout.pageLayouts, (_s.page - 1).clamp(0, c.pageCount - 1));
      return fitFor(fit, c.viewSize, target, _margin).zoom;
    } catch (_) {
      return null;
    }
  }

  FitMode get _defaultFitForMode =>
      _s.mode == ReadingMode.continuous ? FitMode.width : FitMode.page;

  void _setMode(ReadingMode mode) {
    if (mode == _s.mode) return;
    final prevPdfMode = _pdfMode;
    _s.setMode(mode);
    if (mode != ReadingMode.reflow) {
      _s.setFit(mode == ReadingMode.continuous ? FitMode.width : FitMode.page);
      _newBinding(); // fresh controller for the fresh PdfViewer
    } else if (_searchOpen) {
      _closeSearch();
    }
    if (prevPdfMode && mode == ReadingMode.reflow) _editMode.value = false;
    setState(() {});
  }

  void _setFit(FitMode fit) {
    _s.setFit(fit);
    _applyFit(fit);
  }

  // ------------------------------------------------------- viewer callbacks

  void _onViewerReady(PdfDocument document, PdfViewerController controller) {
    if (!identical(controller, _controller)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyFit(_s.fit, duration: Duration.zero);
    });
  }

  void _onPageChanged(int? page) {
    if (page == null || _session == null) return;
    _s.setPage(page);
    _currentPage.value = page;
  }

  bool _onGeneralTap(BuildContext context, PdfViewerController c, PdfViewerGeneralTapHandlerDetails d) {
    if (_editMode.value) return false;
    switch (d.type) {
      case PdfViewerGeneralTapType.tap:
        if (d.tapOn == PdfViewerPart.selectedText) return false;
        if (_s.mode == ReadingMode.singlePage && c.isReady) {
          final w = c.viewSize.width;
          if (d.localPosition.dx < w * 0.2) {
            _goToPage(_s.page - 1);
            return true;
          }
          if (d.localPosition.dx > w * 0.8) {
            _goToPage(_s.page + 1);
            return true;
          }
        }
        _s.toggleChrome();
        return false; // let pdfrx clear any text selection too
      case PdfViewerGeneralTapType.doubleTap:
        final fit = _s.fit == FitMode.custom ? _defaultFitForMode : _s.fit;
        final fz = _fitZoom(fit) ?? c.currentZoom;
        if (c.currentZoom > fz * 1.2) {
          _s.setFit(fit);
          _applyFit(fit);
        } else {
          final z = (c.currentZoom * 2.5).clamp(c.minScale, c.maxScale);
          unawaited(c.zoomOnLocalPosition(localPosition: d.localPosition, newZoom: z));
          _s.setZoom(z, fitZoom: fz);
        }
        return true;
      default:
        return false;
    }
  }

  void _onInteractionStart(ScaleStartDetails d) => _swipeStartPage = _s.page;

  void _onInteractionEnd(ScaleEndDetails d) {
    final c = _readyController;
    if (c == null) return;
    final fitMode = _s.fit == FitMode.custom ? _defaultFitForMode : _s.fit;
    final fz = _fitZoom(fitMode);
    if (_s.mode == ReadingMode.singlePage) {
      final pageFz = _fitZoom(FitMode.page);
      if (pageFz != null && c.currentZoom <= pageFz * 1.05) {
        final vx = d.velocity.pixelsPerSecond.dx;
        final target = vx.abs() > 300
            ? snapTargetPage(current: _swipeStartPage, pageCount: c.pageCount, velocityX: vx)
            : _nearestPage(c);
        _s.setPage(target);
        _currentPage.value = target;
        _s.setFit(FitMode.page);
        _applyFit(FitMode.page, page: target, duration: const Duration(milliseconds: 250));
        return;
      }
    }
    _s.setZoom(c.currentZoom, fitZoom: fz);
  }

  int _nearestPage(PdfViewerController c) {
    final cx = c.visibleRect.center.dx;
    var best = 1;
    var bestD = double.infinity;
    final rects = c.layout.pageLayouts;
    for (var i = 0; i < rects.length; i++) {
      final dist = (rects[i].center.dx - cx).abs();
      if (dist < bestD) {
        bestD = dist;
        best = i + 1;
      }
    }
    return best;
  }

  PdfPageLayout _layoutPages(List<PdfPage> pages, PdfViewerParams params) {
    final l = layoutFor(_s.mode, [for (final p in pages) Size(p.width, p.height)], params.margin);
    return PdfPageLayout(pageLayouts: l.pageRects, documentSize: l.documentSize);
  }

  double _renderScale(BuildContext context, PdfPage page, PdfViewerController c, double estimated) =>
      capRenderScale(page.width, page.height, estimated);

  Future<void> _onLinkTap(PdfLink link) async {
    final dest = link.dest;
    final decision = LinkPolicy.decide(uri: link.url, hasInternalDest: dest != null);
    switch (decision) {
      case LinkDecision.internal:
        if (dest != null) await _readyController?.goToDest(dest);
      case LinkDecision.confirmExternal:
        final uri = link.url!;
        if (!mounted) return;
        if (await confirmExternalLink(context, uri)) {
          final ok = await (widget.urlOpener ?? _launchExternal)(uri);
          if (!ok && mounted) _snack('No app available to open this link.');
        }
      case LinkDecision.blocked:
        _snack('Blocked a link that could be unsafe.');
    }
  }

  List<Widget> _buildPageOverlays(BuildContext context, Rect rect, PdfPage page) {
    final info = ViewerPageInfo(page: page, pageRectInViewer: rect);
    final ctx = _viewerContext;
    return [
      for (final b in _ext.pageOverlays)
        if (b(context, ctx, info) case final w?) Positioned.fill(child: w),
    ];
  }

  // ------------------------------------------------------------------ search

  void _openSearch() {
    if (!_pdfMode) _setMode(ReadingMode.continuous);
    setState(() => _searchOpen = true);
    _s.setChromeVisible(true);
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    _searcher?.resetTextSearch();
    _searchCtl.clear();
    setState(() => _searchOpen = false);
  }

  void _onSearchText(String text) {
    final q = text.trim();
    if (q.isEmpty) {
      _searcher?.resetTextSearch();
      return;
    }
    _searcher?.startTextSearch(q, caseInsensitive: true, goToFirstMatch: true, startPageNumber: _s.page);
  }

  // --------------------------------------------------------------- actions

  void _snack(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  void _maybeSuggestSpread() {
    if (!mounted || _spreadSuggested || _session == null) return;
    if (_s.mode == ReadingMode.twoPage || _s.pageCount < 3) return;
    if (!shouldSuggestSpread(MediaQuery.sizeOf(context))) return;
    _spreadSuggested = true;
    _snack('Large screen: try the two-page view',
        action: SnackBarAction(label: 'Two pages', onPressed: () => _setMode(ReadingMode.twoPage)));
  }

  Future<void> _showGoToPage() async {
    final n = await showGoToPageDialog(context, current: _s.page, pageCount: _s.pageCount);
    if (n != null) _goToPage(n);
  }

  void _showNavigator({int tab = 0}) {
    final theme = ref.read(settingsProvider).value?.defaultPageTheme ?? PageTheme.light;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (c) => NavigatorSheet(
        document: _pdf!,
        currentPage: _s.page,
        bookmarks: _s.bookmarks,
        colorFilter: ReadingThemeSpec.of(theme).filter,
        initialTab: tab,
        onPage: (p) {
          Navigator.pop(c);
          _goToPage(p);
        },
        onOutline: (node) {
          Navigator.pop(c);
          final dest = node.dest;
          if (dest == null) return;
          final c2 = _readyController;
          if (c2 != null && _s.mode == ReadingMode.continuous) {
            unawaited(c2.goToDest(dest));
          } else {
            _goToPage(dest.pageNumber);
          }
        },
        onRemoveBookmark: (p) => _s.toggleBookmark(p),
      ),
    );
  }

  void _changeSettings(AppSettings Function(AppSettings) f) {
    unawaited(() async {
      try {
        await ref.read(settingsProvider.notifier).change(f);
      } catch (_) {}
    }());
  }

  void _showDisplaySheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final settings = ref.watch(settingsProvider).value ?? const AppSettings();
          return ListenableBuilder(
            listenable: _s,
            builder: (c, _) => _DisplaySheet(
              mode: _s.mode,
              fit: _s.fit,
              theme: settings.defaultPageTheme,
              fontScale: settings.textScale,
              onMode: _setMode,
              onFit: _setFit,
              onTheme: (t) => _changeSettings((s) => s.copyWith(defaultPageTheme: t)),
              onFontScale: (v) => _changeSettings((s) => s.copyWith(textScale: v)),
            ),
          );
        },
      ),
    );
  }

  Future<void> _share() async {
    try {
      await ref.read(shareServiceProvider).shareFiles([widget.document.path], subject: widget.document.displayName);
    } catch (_) {
      _snack("Sharing isn't available right now.");
    }
  }

  void _toggleEdit() {
    final on = !_editMode.value;
    _editMode.value = on;
    if (on && !_pdfMode) _setMode(ReadingMode.continuous);
    _ext.onEdit?.call(context, _viewerContext, on);
    setState(() {});
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    switch (_phase) {
      case _Phase.loading:
        return Scaffold(
          appBar: AppBar(title: Text(widget.document.displayName)),
          body: Center(
            child: Semantics(
              label: 'Opening document',
              child: const CircularProgressIndicator(),
            ),
          ),
        );
      case _Phase.error:
        return _ErrorView(
          name: widget.document.displayName,
          failure: _failure ?? OpenFailure.corrupted,
          onRetry: _open,
        );
      case _Phase.ready:
        break;
    }
    _setWakelock(settings.keepScreenOn);
    final spec = ReadingThemeSpec.of(settings.defaultPageTheme);
    final chrome = _s.chromeVisible || _searchOpen;
    final duration = Motion.of(context, Motion.normal);

    return Scaffold(
      backgroundColor: spec.background,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody(settings, spec)),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _ChromeSlot(
              visible: chrome,
              offset: const Offset(0, -1),
              duration: duration,
              child: _searchOpen ? _buildSearchBar() : _buildAppBar(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ChromeSlot(
              visible: chrome,
              offset: const Offset(0, 1),
              duration: duration,
              child: _buildBottomBar(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppSettings settings, ReadingThemeSpec spec) {
    if (_s.mode == ReadingMode.reflow) {
      return ReflowView(
        key: _reflowKey,
        pageCount: _s.pageCount,
        loadText: pdfPageTextLoader(_pdf!),
        theme: settings.defaultPageTheme,
        fontScale: settings.textScale,
        initialPage: _s.page,
        onPageChanged: (p) {
          _s.setPage(p);
          _currentPage.value = p;
        },
        onTap: _s.toggleChrome,
      );
    }
    final c = _controller!;
    final searcher = _searcher!;
    final ext = _ext;
    return ValueListenableBuilder<bool>(
      valueListenable: _editMode,
      builder: (context, editing, _) => PdfViewer(
        _ref!,
        key: ValueKey('viewer$_viewerGen'),
        controller: c,
        initialPageNumber: _s.page,
        params: PdfViewerParams(
          margin: _margin,
          backgroundColor: spec.background,
          pageImageColorFilter: spec.filter,
          layoutPages: _s.mode == ReadingMode.continuous ? null : _layoutPages,
          pageAnchor: _s.mode == ReadingMode.continuous ? PdfPageAnchor.top : PdfPageAnchor.center,
          onViewerReady: _onViewerReady,
          onPageChanged: _onPageChanged,
          onGeneralTap: _onGeneralTap,
          onInteractionStart: _onInteractionStart,
          onInteractionEnd: _onInteractionEnd,
          getPageRenderingScale: _renderScale,
          linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _onLinkTap),
          textSelectionParams: PdfTextSelectionParams(enabled: !editing),
          matchTextColor: const Color(0x80FFEB3B),
          activeMatchTextColor: const Color(0xA0FF9800),
          pagePaintCallbacks: [searcher.pageTextMatchPaintCallback],
          pageOverlaysBuilder: ext.pageOverlays.isEmpty ? null : _buildPageOverlays,
          viewerOverlayBuilder: _s.mode == ReadingMode.singlePage
              ? null
              : (context, size, handleLinkTap) => [
                    PdfViewerScrollThumb(
                      controller: c,
                      orientation: ScrollbarOrientation.right,
                      thumbSize: const Size(44, 32),
                      thumbBuilder: (context, thumbSize, pageNumber, controller) => Semantics(
                        label: 'Scroll position, page ${pageNumber ?? ''}',
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.secondaryContainer,
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(Radii.md)),
                            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                          ),
                          alignment: Alignment.center,
                          child: Text(pageNumber?.toString() ?? '',
                              style: TextStyle(
                                  fontSize: 12, color: Theme.of(context).colorScheme.onSecondaryContainer)),
                        ),
                      ),
                    ),
                  ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    final ext = _ext;
    final bookmarked = _s.isBookmarked;
    return AppBar(
      title: Text(widget.document.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      leading: BackButton(onPressed: () => Navigator.maybePop(context)),
      actions: [
        IconButton(tooltip: 'Search in document', icon: const Icon(Icons.search), onPressed: _openSearch),
        IconButton(
          tooltip: bookmarked ? 'Remove bookmark from this page' : 'Bookmark this page',
          isSelected: bookmarked,
          icon: const Icon(Icons.bookmark_border),
          selectedIcon: const Icon(Icons.bookmark),
          onPressed: () => _s.toggleBookmark(),
        ),
        IconButton(
          tooltip: 'Reading mode, page colour and text size',
          icon: const Icon(Icons.text_format),
          onPressed: _showDisplaySheet,
        ),
        if (ext.onEdit != null)
          IconButton(
            tooltip: _editMode.value ? 'Stop editing' : 'Edit',
            isSelected: _editMode.value,
            icon: const Icon(Icons.edit_outlined),
            selectedIcon: const Icon(Icons.edit),
            onPressed: _toggleEdit,
          ),
        PopupMenuButton<String>(
          tooltip: 'More options',
          onSelected: (v) {
            switch (v) {
              case 'goto':
                unawaited(_showGoToPage());
              case 'contents':
                _showNavigator(tab: 1);
              case 'bookmarks':
                _showNavigator(tab: 2);
              case 'organize':
                unawaited(context.push(Routes.organize, extra: widget.document));
              case 'export':
                unawaited(context.push(Routes.export, extra: widget.document));
              case 'share':
                unawaited(_share());
              default:
                for (final a in ext.extraActions) {
                  if (a.id == v) a.onPressed(context, _viewerContext);
                }
            }
          },
          itemBuilder: (c) => [
            _menuItem('goto', Icons.input, 'Go to page…'),
            _menuItem('contents', Icons.toc, 'Contents'),
            _menuItem('bookmarks', Icons.bookmarks_outlined, 'Bookmarks'),
            const PopupMenuDivider(),
            _menuItem('organize', Icons.view_module_outlined, 'Organize pages'),
            _menuItem('export', Icons.file_download_outlined, 'Export'),
            _menuItem('share', Icons.share_outlined, 'Share'),
            for (final a in ext.extraActions) _menuItem(a.id, a.icon, a.label),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String v, IconData icon, String label) => PopupMenuItem(
        value: v,
        child: ListTile(leading: Icon(icon), title: Text(label), contentPadding: EdgeInsets.zero),
      );

  Widget _buildSearchBar() {
    final s = _searcher!;
    final total = s.matches.length;
    final idx = s.currentIndex;
    final label = _searchCtl.text.trim().isEmpty
        ? ''
        : total == 0
            ? (s.isSearching ? 'Searching…' : 'No results')
            : '${idx == null ? 0 : idx + 1} / $total${s.isSearching ? '+' : ''}';
    return AppBar(
      leading: IconButton(tooltip: 'Close search', icon: const Icon(Icons.close), onPressed: _closeSearch),
      title: TextField(
        key: const Key('searchField'),
        controller: _searchCtl,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(hintText: 'Find in document', border: InputBorder.none),
        onChanged: _onSearchText,
        onSubmitted: (_) => unawaited(s.goToNextMatch()),
      ),
      actions: [
        Center(
          child: Semantics(
            liveRegion: true,
            child: Text(label, key: const Key('searchCount')),
          ),
        ),
        IconButton(
          tooltip: 'Previous match',
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: total == 0 ? null : () => unawaited(s.goToPrevMatch()),
        ),
        IconButton(
          tooltip: 'Next match',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: total == 0 ? null : () => unawaited(s.goToNextMatch()),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    final ext = _ext;
    if (_editMode.value && ext.editToolbarBuilder != null) {
      return Material(
        elevation: 3,
        child: SafeArea(top: false, child: ext.editToolbarBuilder!(context, _viewerContext)),
      );
    }
    final count = _s.pageCount;
    final page = _s.page;
    final shown = (_scrubValue ?? page.toDouble()).round();
    return Material(
      elevation: 3,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Pages, contents and bookmarks',
                icon: const Icon(Icons.grid_view),
                onPressed: () => _showNavigator(),
              ),
              Expanded(
                child: count > 1
                    ? Slider(
                        key: const Key('pageScrubber'),
                        min: 1,
                        max: count.toDouble(),
                        divisions: count > 1 ? count - 1 : null,
                        value: (_scrubValue ?? page.toDouble()).clamp(1, count.toDouble()),
                        label: 'Page $shown',
                        semanticFormatterCallback: (v) => 'Page ${v.round()} of $count',
                        onChanged: (v) => setState(() => _scrubValue = v),
                        onChangeEnd: (v) {
                          setState(() => _scrubValue = null);
                          _goToPage(v.round());
                        },
                      )
                    : const SizedBox.shrink(),
              ),
              Semantics(
                button: true,
                label: 'Page $shown of $count. Go to page',
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
                  onTap: _showGoToPage,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: kMinTouchTarget, minWidth: kMinTouchTarget),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                        child: Text('$shown / $count',
                            key: const Key('pageIndicator'),
                            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slides chrome in/out and removes it from hit-testing while hidden.
class _ChromeSlot extends StatelessWidget {
  const _ChromeSlot({required this.visible, required this.offset, required this.duration, required this.child});
  final bool visible;
  final Offset offset;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : offset,
            duration: duration,
            curve: Motion.standard,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: duration,
              child: child,
            ),
          ),
        ),
      );
}

class _DisplaySheet extends StatelessWidget {
  const _DisplaySheet({
    required this.mode,
    required this.fit,
    required this.theme,
    required this.fontScale,
    required this.onMode,
    required this.onFit,
    required this.onTheme,
    required this.onFontScale,
  });

  final ReadingMode mode;
  final FitMode fit;
  final PageTheme theme;
  final double fontScale;
  final ValueChanged<ReadingMode> onMode;
  final ValueChanged<FitMode> onFit;
  final ValueChanged<PageTheme> onTheme;
  final ValueChanged<double> onFontScale;

  static String themeLabel(PageTheme t) => switch (t) {
        PageTheme.light => 'Light',
        PageTheme.sepia => 'Sepia',
        PageTheme.dark => 'Dark',
        PageTheme.night => 'Night',
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Reading mode', style: text.titleSmall),
          const SizedBox(height: Space.sm),
          Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            for (final (m, icon, label) in const [
              (ReadingMode.continuous, Icons.view_day_outlined, 'Scroll'),
              (ReadingMode.singlePage, Icons.crop_portrait, 'Single page'),
              (ReadingMode.twoPage, Icons.menu_book_outlined, 'Two pages'),
              (ReadingMode.reflow, Icons.notes, 'Text'),
            ])
              ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: mode == m,
                onSelected: (_) => onMode(m),
              ),
          ]),
          if (mode != ReadingMode.reflow) ...[
            const SizedBox(height: Space.md),
            Text('Zoom', style: text.titleSmall),
            const SizedBox(height: Space.sm),
            Wrap(spacing: Space.sm, children: [
              ChoiceChip(
                avatar: const Icon(Icons.fit_screen_outlined, size: 18),
                label: const Text('Fit width'),
                selected: fit == FitMode.width,
                onSelected: (_) => onFit(FitMode.width),
              ),
              ChoiceChip(
                avatar: const Icon(Icons.crop_free, size: 18),
                label: const Text('Fit page'),
                selected: fit == FitMode.page,
                onSelected: (_) => onFit(FitMode.page),
              ),
            ]),
          ],
          const SizedBox(height: Space.md),
          Text('Page colour', style: text.titleSmall),
          const SizedBox(height: Space.sm),
          Wrap(spacing: Space.md, runSpacing: Space.sm, children: [
            for (final t in PageTheme.values)
              Semantics(
                button: true,
                selected: t == theme,
                label: '${themeLabel(t)} page colour',
                excludeSemantics: true,
                child: Tooltip(
                  message: themeLabel(t),
                  child: InkResponse(
                    onTap: () => onTheme(t),
                    radius: 28,
                    child: Column(children: [
                      Container(
                        width: kMinTouchTarget,
                        height: kMinTouchTarget,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: reflowColors(t).background,
                          border: Border.all(
                            color: t == theme
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outlineVariant,
                            width: t == theme ? 3 : 1,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text('Aa', style: TextStyle(color: reflowColors(t).text)),
                      ),
                      const SizedBox(height: Space.xs),
                      Text(themeLabel(t), style: text.labelSmall),
                    ]),
                  ),
                ),
              ),
          ]),
          if (mode == ReadingMode.reflow) ...[
            const SizedBox(height: Space.md),
            Text('Text size', style: text.titleSmall),
            Row(children: [
              const Icon(Icons.text_decrease, semanticLabel: 'Smaller'),
              Expanded(
                child: Slider(
                  min: 0.8,
                  max: 2.0,
                  divisions: 12,
                  value: fontScale.clamp(0.8, 2.0),
                  label: '${(fontScale * 100).round()}%',
                  semanticFormatterCallback: (v) => 'Text size ${(v * 100).round()} percent',
                  onChanged: onFontScale,
                ),
              ),
              const Icon(Icons.text_increase, semanticLabel: 'Larger'),
            ]),
          ],
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.name, required this.failure, required this.onRetry});
  final String name;
  final OpenFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final d = describeFailure(failure);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(d.icon, size: 64, color: scheme.error),
              const SizedBox(height: Space.md),
              Text(d.title,
                  key: const Key('errorTitle'),
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: Space.sm),
              Text(d.message, textAlign: TextAlign.center),
              const SizedBox(height: Space.lg),
              Wrap(spacing: Space.md, alignment: WrapAlignment.center, children: [
                OutlinedButton(onPressed: () => Navigator.maybePop(context), child: const Text('Back')),
                if (d.canRetry)
                  FilledButton(
                    onPressed: onRetry,
                    child: Text(failure == OpenFailure.cancelled || failure == OpenFailure.wrongPassword
                        ? 'Enter password'
                        : 'Try again'),
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
