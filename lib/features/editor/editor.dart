/// Editing feature: annotations, signatures, page organising, forms, saving.
///
/// ## Plugging into the viewer (`viewer_hooks.dart`)
///
/// Replace the single `viewerExtensionsProvider` line with:
///
/// ```dart
/// final viewerExtensionsProvider = Provider<ViewerExtensions>((ref) {
///   final editor = ref.watch(editorBridgeProvider);
///   return ViewerExtensions(
///     pageOverlays: [
///       (context, vc, page) => editor.overlay(vc.document, page.page, page.pdfToLocal),
///     ],
///     onEdit: (context, vc, enabled) => editor.setEditing(vc.document, enabled),
///     editToolbarBuilder: (context, vc) => editor.toolbar(context, vc.document),
///     extraActions: [
///       ViewerAction(id: 'organize', label: 'Organize pages', icon: Icons.grid_view,
///           onPressed: (c, vc) => c.push(Routes.organize, extra: vc.document)),
///       ViewerAction(id: 'fill-form', label: 'Fill form', icon: Icons.edit_note,
///           onPressed: (c, vc) => editor.fillForm(c, vc.document, vc.pdf)),
///       ViewerAction(id: 'save-annotated', label: 'Save with annotations', icon: Icons.save_alt,
///           onPressed: (c, vc) => editor.saveAnnotated(vc.document, vc.pdf)),
///     ],
///   );
/// });
/// ```
///
/// * The overlay ignores all pointers while edit mode is off (tool "Read");
///   with the Select tool it only claims pointers that hit an annotation, so
///   the viewer keeps scrolling/zooming elsewhere. Drawing tools claim the
///   whole page.
/// * Text selection → markup: `editor.markup(doc, pageNumber, MarkupKind.highlight,
///   [for (final r in pdfRects) Rect.fromLTRB(r.left, r.bottom, r.right, r.top)], text: t)`.
/// * Coordinates: PDF points, origin bottom-left, unrotated page (same as
///   pdfrx `PdfRect`). Rects are stored normalised (top <= bottom numerically).
/// * Annotations autosave to the app-private sidecar (debounced); "Save with
///   annotations" flattens them into a copy in `<appSupport>/documents/`
///   (export with `FilePickService.saveAs`).
///
/// Without the bridge, a screen can use [EditorSession] directly
/// (`overlayForPdfPage`, `toolbar`, `saveWithAnnotations`, `openFormFill`).
///
/// Providers wired here: `pageEditorProvider` → [PdfrxPageEditor],
/// `saveServiceProvider` → [FileSaveService], plus [editorBridgeProvider].
library;

export 'annotation_controller.dart';
export 'editor_session.dart';
export 'editor_tools.dart';
export 'editor_viewer_bridge.dart';
export 'engine/flattener.dart' show Flattener, SignatureLoader;
export 'engine/pdfrx_page_editor.dart';
export 'forms/form_engine.dart';
export 'forms/form_fill_controller.dart';
export 'forms/form_fill_screen.dart';
export 'model/annotation_ops.dart';
export 'model/page_transform.dart';
export 'organize_screen.dart';
export 'save/file_save_service.dart';
export 'signature/signature_pad_screen.dart';
export 'signature/signature_picker.dart';
export 'signature/signature_store.dart';
export 'widgets/annotation_layer.dart';
export 'widgets/editing_toolbar.dart';
