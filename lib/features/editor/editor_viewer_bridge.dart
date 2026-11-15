import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models/annotation.dart';
import '../../core/models/document_ref.dart';
import '../../core/providers.dart';
import 'editor_session.dart';
import 'editor_tools.dart';
import 'model/page_transform.dart';

/// Glue between the viewer's extension hooks (`viewer_hooks.dart`:
/// ViewerExtensions / ViewerContext / ViewerPageInfo) and the editor. It only
/// takes primitives so this feature does not depend on viewer files; see the
/// recipe in `editor.dart`.
///
/// Keeps one [EditorSession] per open document (at most [maxSessions]; the
/// least recently used is flushed and disposed).
class EditorBridge {
  EditorBridge(this._ref, {this.maxSessions = 4});
  final Ref _ref;
  final int maxSessions;
  final Map<String, EditorSession> _sessions = {};

  EditorSession sessionFor(DocumentRef doc) {
    final existing = _sessions.remove(doc.id);
    if (existing != null) return _sessions[doc.id] = existing; // mark recently used
    final s = EditorSession(
      document: doc,
      annotationStore: _ref.read(annotationStoreProvider),
      dirs: _ref.read(appDirsProvider),
    );
    _sessions[doc.id] = s;
    s.load().ignore();
    while (_sessions.length > maxSessions) {
      final oldest = _sessions.keys.first;
      _sessions.remove(oldest)!.dispose();
    }
    return s;
  }

  /// ViewerOverlayBuilder body. [pdfToLocal] = `ViewerPageInfo.pdfToLocal`.
  Widget overlay(DocumentRef doc, PdfPage page, Offset Function(Offset pdf) pdfToLocal) {
    final unrotated = page.rotation.index.isOdd ? Size(page.height, page.width) : Size(page.width, page.height);
    return sessionFor(doc).overlayForPage(
      pageNumber: page.pageNumber,
      pageSize: unrotated,
      viewSize: Size.zero,
      transform: matrixFromPointMapper(pdfToLocal),
    );
  }

  /// ViewerExtensions.onEdit body: edit mode on → Select tool, off → Read.
  void setEditing(DocumentRef doc, bool enabled) {
    final s = sessionFor(doc);
    s.tool.tool = enabled ? EditorTool.select : EditorTool.none;
    if (!enabled) s.controller.select(null);
  }

  /// ViewerExtensions.editToolbarBuilder body.
  Widget toolbar(BuildContext context, DocumentRef doc) => sessionFor(doc).toolbar(context);

  /// Highlight / underline / strike-out the viewer's text selection.
  /// [pdfRects] in PDF points (any edge order).
  Future<void> markup(DocumentRef doc, int pageNumber, MarkupKind kind, List<Rect> pdfRects, {String? text}) =>
      sessionFor(doc).markupSelection(pageNumber: pageNumber, kind: kind, rects: pdfRects, text: text);

  /// "Save with annotations" action: flattens into an app-private copy.
  Future<String> saveAnnotated(DocumentRef doc, PdfDocument pdf) => sessionFor(doc).saveWithAnnotations(
      pdf: pdf, editor: _ref.read(pageEditorProvider), saveService: _ref.read(saveServiceProvider));

  /// "Fill form" action.
  Future<String?> fillForm(BuildContext context, DocumentRef doc, PdfDocument pdf) =>
      sessionFor(doc).openFormFill(context, pdf);

  void disposeAll() {
    for (final s in _sessions.values) {
      s.dispose();
    }
    _sessions.clear();
  }
}

final editorBridgeProvider = Provider<EditorBridge>((ref) {
  final b = EditorBridge(ref);
  ref.onDispose(b.disposeAll);
  return b;
});
