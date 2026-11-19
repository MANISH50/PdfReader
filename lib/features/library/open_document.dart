import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app_router.dart';
import '../../core/models/document_ref.dart';
import '../../core/pdf/document_service.dart';
import '../../core/providers.dart';
import '../../ui/design_system/adaptive.dart';
import 'recents_controller.dart';

/// User-facing message for an open/import failure (never raw exception text).
String friendlyOpenError(Object error) {
  if (error is DocumentOpenException) {
    return switch (error.failure) {
      OpenFailure.notFound => 'That file is no longer available.',
      OpenFailure.tooLarge => 'That file is too large to open safely.',
      OpenFailure.tooManyPages => 'That document has too many pages to open safely.',
      OpenFailure.notPdf => "That file isn't a PDF.",
      OpenFailure.corrupted => 'That PDF looks damaged and couldn’t be opened.',
      OpenFailure.wrongPassword => 'Wrong password.',
      OpenFailure.cancelled => 'Cancelled.',
      OpenFailure.timeout => 'Opening took too long. Please try again.',
      OpenFailure.unsafe => 'This file looks unsafe or too complex to open.',
      OpenFailure.unsupported => "This file type isn't supported.",
    };
  }
  return 'Couldn’t open that file. Please try again.';
}

/// Picks one or more PDFs with the system picker and imports them. With
/// [anyDocument], one file of any supported kind (PDF, DOCX, Markdown, text).
/// Returns an empty list if the user cancelled; shows a snackbar and
/// returns null on failure.
Future<List<DocumentRef>?> pickAndImport(
  BuildContext context,
  WidgetRef ref, {
  bool multiple = false,
  bool anyDocument = false,
}) async {
  try {
    final picker = ref.read(filePickServiceProvider);
    final paths = anyDocument ? await picker.pickDocuments() : await picker.pickPdfs(multiple: multiple);
    if (paths.isEmpty) return const [];
    final service = ref.read(documentServiceProvider);
    return [for (final p in paths) await service.importFile(p)];
  } catch (e) {
    if (e is DocumentOpenException && e.failure == OpenFailure.cancelled) return const [];
    if (context.mounted) showAppSnackBar(context, friendlyOpenError(e));
    return null;
  }
}

/// Pushes the right screen for [doc]: the PDF viewer, or the reader for
/// DOCX / Markdown / text. Every place that opens a document goes through here.
Future<void> openDocumentRoute(BuildContext context, DocumentRef doc) =>
    context.push(documentRouteFor(doc), extra: doc);

/// Opens [doc] (viewer or reader), recording it in recents first.
Future<void> openInViewer(BuildContext context, WidgetRef ref, DocumentRef doc) async {
  try {
    await ref.read(recentsProvider.notifier).touch(doc);
  } catch (_) {
    // Recents are a convenience; never block opening on them.
  }
  if (!context.mounted) return;
  await openDocumentRoute(context, doc);
  ref.invalidate(recentsProvider); // reading position may have changed
}
