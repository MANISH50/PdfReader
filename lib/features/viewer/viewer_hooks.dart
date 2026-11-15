import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models/document_ref.dart';
import '../editor/viewer_integration.dart';

/// Extension points of the viewer. See the comment at the top of
/// `viewer_screen.dart` for how the Editing agent plugs in.

/// Geometry of one page as currently drawn by the viewer, with transforms
/// between **PDF page coordinates** (points, origin bottom-left, unrotated
/// page — the convention of `Annotation`) and the overlay's local coordinates
/// (origin top-left of the page as drawn, logical pixels).
class ViewerPageInfo {
  const ViewerPageInfo({required this.page, required this.pageRectInViewer});

  /// pdfrx page (1-based [PdfPage.pageNumber]).
  final PdfPage page;

  /// Where the page is drawn, in the viewer widget's local coordinates.
  /// The overlay widget is laid out exactly over this rect.
  final Rect pageRectInViewer;

  int get pageNumber => page.pageNumber;

  /// Rendered size of the page (overlay size).
  Size get size => pageRectInViewer.size;

  /// Logical pixels per PDF point at the current zoom.
  double get scale => page.width == 0 ? 1 : pageRectInViewer.width / page.width;

  /// PDF point (bottom-left origin) → overlay-local offset.
  Offset pdfToLocal(Offset pdfPoint) =>
      PdfPoint(pdfPoint.dx, pdfPoint.dy).toOffset(page: page, scaledPageSize: size);

  /// Overlay-local offset → PDF point (bottom-left origin).
  Offset localToPdf(Offset local) {
    final pt = local.toPdfPoint(page: page, scaledPageSize: size);
    return Offset(pt.x, pt.y);
  }

  /// PDF rect (LTRB in PDF points as stored by annotations, i.e. top > bottom
  /// allowed either way) → overlay-local rect.
  Rect pdfRectToLocal(Rect pdfRect) => Rect.fromPoints(
        pdfToLocal(pdfRect.topLeft),
        pdfToLocal(pdfRect.bottomRight),
      );

  /// Overlay-local rect → PDF rect (normalized so left<right, bottom<top in
  /// PDF space is represented as Rect with top < bottom numerically).
  Rect localRectToPdf(Rect local) => Rect.fromPoints(localToPdf(local.topLeft), localToPdf(local.bottomRight));
}

/// State the viewer shares with plug-ins.
class ViewerContext {
  const ViewerContext({
    required this.document,
    required this.pdf,
    required this.controller,
    required this.currentPage,
    required this.editMode,
  });

  final DocumentRef document;
  final PdfDocument pdf;

  /// Controller of the live [PdfViewer] (null in reflow/text mode).
  final PdfViewerController? controller;

  /// 1-based current page.
  final ValueListenable<int> currentPage;

  /// True while the user is in edit mode (toggled by the "Edit" action).
  /// Overlays should accept input only while this is true so normal reading
  /// gestures (scroll, zoom, select) keep working.
  final ValueNotifier<bool> editMode;
}

/// Builds a widget stacked over one page. Return null for nothing.
/// The widget is positioned over [ViewerPageInfo.pageRectInViewer]. To handle
/// taps while still letting the viewer pan/zoom, wrap it in pdfrx's
/// `PdfOverlayInteractionRegion`; for full gesture capture (ink), use a
/// GestureDetector only while `ctx.editMode.value` is true.
typedef ViewerOverlayBuilder = Widget? Function(
    BuildContext context, ViewerContext ctx, ViewerPageInfo page);

/// A toolbar/menu action contributed to the viewer.
class ViewerAction {
  const ViewerAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String id;
  final String label;
  final IconData icon;
  final void Function(BuildContext context, ViewerContext ctx) onPressed;
}

/// Everything plug-ins contribute. All fields are optional.
class ViewerExtensions {
  const ViewerExtensions({
    this.pageOverlays = const [],
    this.onEdit,
    this.editToolbarBuilder,
    this.extraActions = const [],
  });

  /// Per-page overlays (e.g. the annotation layer), stacked in order.
  final List<ViewerOverlayBuilder> pageOverlays;

  /// When non-null the viewer shows an "Edit" button. The viewer toggles
  /// [ViewerContext.editMode] and then calls this (e.g. to load annotations).
  final void Function(BuildContext context, ViewerContext ctx, bool enabled)? onEdit;

  /// Shown in place of the reading bottom bar while edit mode is on
  /// (annotation tool palette).
  final Widget Function(BuildContext context, ViewerContext ctx)? editToolbarBuilder;

  /// Additional overflow-menu actions.
  final List<ViewerAction> extraActions;
}

/// Override this (ProviderScope override or by changing this single line) to
/// plug the editor into the viewer.
final viewerExtensionsProvider = Provider<ViewerExtensions>(editorViewerExtensions);

/// Opens external URLs after the user confirmed them. Seam for tests.
typedef UrlOpener = Future<bool> Function(Uri uri);
