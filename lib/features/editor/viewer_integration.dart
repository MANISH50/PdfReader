import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../viewer/viewer_hooks.dart';
import 'editor_viewer_bridge.dart';

/// Plugs the editor (annotation overlay, edit toolbar, forms, save) into the
/// viewer; the default value of [viewerExtensionsProvider].
ViewerExtensions editorViewerExtensions(Ref ref) {
  final editor = ref.watch(editorBridgeProvider);
  return ViewerExtensions(
    pageOverlays: [
      (context, vc, page) => editor.overlay(vc.document, page.page, page.pdfToLocal),
    ],
    onEdit: (context, vc, enabled) => editor.setEditing(vc.document, enabled),
    editToolbarBuilder: (context, vc) => editor.toolbar(context, vc.document),
    extraActions: [
      ViewerAction(
        id: 'fill-form',
        label: 'Fill form',
        icon: Icons.edit_note,
        onPressed: (c, vc) => editor.fillForm(c, vc.document, vc.pdf),
      ),
      ViewerAction(
        id: 'save-annotated',
        label: 'Save copy with annotations',
        icon: Icons.save_alt,
        onPressed: (c, vc) async {
          final messenger = ScaffoldMessenger.maybeOf(c);
          try {
            await editor.saveAnnotated(vc.document, vc.pdf);
            messenger?.showSnackBar(const SnackBar(
                content: Text('Saved a copy with your annotations. Use Export or Share to send it.')));
          } catch (_) {
            messenger?.showSnackBar(const SnackBar(content: Text('Could not save the copy.')));
          }
        },
      ),
    ],
  );
}
