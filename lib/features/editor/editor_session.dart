import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/commands/undo_stack.dart';
import '../../core/models/annotation.dart';
import '../../core/models/document_ref.dart';
import '../../core/pdf/page_editor.dart';
import '../../core/storage/app_storage.dart';
import '../../core/storage/stores.dart';
import 'annotation_controller.dart';
import 'editor_tools.dart';
import 'forms/form_fill_screen.dart';
import 'model/page_transform.dart';
import 'signature/signature_picker.dart';
import 'signature/signature_store.dart';
import 'widgets/annotation_layer.dart';
import 'widgets/editing_toolbar.dart';

/// Everything the viewer needs to make one open document editable. Create
/// one per document (e.g. in the ViewerScreen state), call [load], and
/// [dispose] it with the screen. See `editor.dart` for the integration
/// recipe.
class EditorSession {
  EditorSession({
    required this.document,
    required AnnotationStore annotationStore,
    required AppDirs dirs,
    UndoStack? undoStack,
  })  : signatures = SignatureStore(dirs.signatures),
        controller = AnnotationController(docId: document.id, store: annotationStore, undoStack: undoStack) {
    signatureImages = SignatureImageCache(signatures);
  }

  final DocumentRef document;
  final AnnotationController controller;
  final EditorToolState tool = EditorToolState();
  final SignatureStore signatures;
  late final SignatureImageCache signatureImages;

  UndoStack get undoStack => controller.undoStack;

  Future<void> load() => controller.load();

  /// Overlay for one rendered page. [pageSize] is the UNROTATED size in PDF
  /// points; [viewSize] the on-screen size of the page widget; [quarterTurns]
  /// the clockwise display rotation (pdfrx `page.rotation.index`).
  Widget overlayForPage({
    required int pageNumber,
    required Size pageSize,
    required Size viewSize,
    int quarterTurns = 0,
    Matrix4? transform,
  }) =>
      AnnotationLayer(
        key: ValueKey('annotations-${document.id}-$pageNumber'),
        page: pageNumber,
        pageSize: pageSize,
        transform: transform ?? pdfToViewMatrix(pageSize: pageSize, quarterTurns: quarterTurns, viewSize: viewSize),
        controller: controller,
        tool: tool,
        signatureImages: signatureImages,
        onRequestSignature: _requestSignature,
      );

  /// Convenience for a pdfrx page.
  Widget overlayForPdfPage(PdfPage page, Size viewSize) => overlayForPage(
        pageNumber: page.pageNumber,
        pageSize: page.rotation.index.isOdd ? Size(page.height, page.width) : Size(page.width, page.height),
        viewSize: viewSize,
        quarterTurns: page.rotation.index,
      );

  BuildContext? _context;

  /// The bottom editing toolbar. Pass a [context] under a Navigator so the
  /// signature picker can open.
  Widget toolbar(BuildContext context) {
    _context = context;
    return EditingToolbar(tool: tool, controller: controller, onSignatureTool: _requestSignature);
  }

  Future<void> _requestSignature() async {
    final ctx = _context;
    if (ctx == null || !ctx.mounted) return;
    final id = await pickSignature(ctx, signatures);
    if (id != null) tool.signatureId = id;
  }

  /// Adds a highlight/underline/strike-out for the viewer's current text
  /// selection. [rects] in PDF space (pdfrx `PdfRect` → use
  /// `Rect.fromLTRB(r.left, r.bottom, r.right, r.top)`).
  Future<void> markupSelection({
    required int pageNumber,
    required MarkupKind kind,
    required List<Rect> rects,
    String? text,
    Color? color,
  }) =>
      controller.addTextMarkup(
          page: pageNumber, kind: kind, rects: rects, text: text, color: color ?? kAnnotationPalette.first);

  /// Burns all annotations into a new PDF and saves it with [saveService]
  /// (copy by default). Returns the saved path.
  Future<String> saveWithAnnotations({
    required PdfDocument pdf,
    required PageEditor editor,
    required SaveService saveService,
    SaveMode mode = SaveMode.saveAsCopy,
  }) async {
    await controller.flush();
    final bytes = await editor.flatten(pdf, controller.annotations);
    final path = await saveService.save(bytes,
        mode: mode,
        suggestedName: '${document.baseName} (annotated).pdf',
        originalPath: mode == SaveMode.overwriteOriginal ? document.path : null);
    undoStack.markSaved();
    return path;
  }

  /// Opens the form-filling screen. Returns the saved copy's path or null.
  Future<String?> openFormFill(BuildContext context, PdfDocument pdf) => Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => FormFillScreen(document: document, pdf: pdf)));

  void dispose() {
    controller.dispose();
    tool.dispose();
    signatureImages.dispose();
  }
}
