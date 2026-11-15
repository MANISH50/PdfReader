import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../app_router.dart';
import '../core/models/document_ref.dart';
import '../core/pdf/document_service.dart';
import '../core/providers.dart';
import 'incoming_file_service_impl.dart';
import 'platform_services.dart';

/// Opens files handed to the app by other apps ("Open with", share sheet,
/// iOS "Open in"). Wrap the app's navigator with it — in `app.dart`:
///
/// ```dart
/// MaterialApp.router(
///   ...
///   routerConfig: _router,
///   builder: (context, child) =>
///       IncomingFileListener(router: _router, child: child ?? const SizedBox.shrink()),
/// )
/// ```
///
/// Each file is imported through [DocumentService.importFile] and opened in
/// the viewer (pushed, so Back returns to where the user was). When several
/// files arrive together (multi-share), the first opens and the rest are
/// added to Recents.
class IncomingFileListener extends ConsumerStatefulWidget {
  const IncomingFileListener({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<IncomingFileListener> createState() => _IncomingFileListenerState();
}

class _IncomingFileListenerState extends ConsumerState<IncomingFileListener> {
  /// Files arriving within this window of an opened file count as one batch.
  static const _batchWindow = Duration(seconds: 3);

  StreamSubscription<IncomingFile>? _filesSub;
  StreamSubscription<IncomingFailure>? _failuresSub;
  Future<void> _queue = Future.value();
  DateTime? _lastOpened;
  int _batchExtra = 0;

  @override
  void initState() {
    super.initState();
    final service = ref.read(incomingFileServiceProvider);
    if (service is IncomingFailureSource) {
      _failuresSub = (service as IncomingFailureSource).failures.listen(_onFailure);
    }
    _enqueue(() async {
      final first = await service.initialFile();
      if (first != null) await _open(first);
    });
    _filesSub = service.files.listen((f) => _enqueue(() => _open(f)));
  }

  @override
  void dispose() {
    unawaited(_filesSub?.cancel());
    unawaited(_failuresSub?.cancel());
    super.dispose();
  }

  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) => task()).catchError((Object _) {});
  }

  Future<void> _open(IncomingFile file) async {
    final DocumentRef doc;
    try {
      doc = await ref
          .read(documentServiceProvider)
          .importFile(file.path, displayName: file.displayName, sourceUri: file.sourceUri);
    } on DocumentOpenException catch (e) {
      _snack(_openFailureText(e.failure, file.displayName));
      return;
    } catch (_) {
      _snack('Couldn\'t open ${file.displayName ?? 'the file'}.');
      return;
    }
    if (!mounted) return;

    final now = DateTime.now();
    final last = _lastOpened;
    if (last != null && now.difference(last) < _batchWindow) {
      // Part of a multi-file share: keep it in Recents, don't stack viewers.
      await ref.read(recentFilesStoreProvider).touch(doc);
      _batchExtra++;
      _snack(_batchExtra == 1
          ? '1 more file added to Recent files.'
          : '$_batchExtra more files added to Recent files.');
      return;
    }
    _lastOpened = now;
    _batchExtra = 0;
    // Navigate after the current frame so a cold-start router is ready.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    unawaited(widget.router.push(Routes.viewer, extra: doc));
  }

  void _onFailure(IncomingFailure f) {
    final name = f.displayName ?? 'The file';
    _snack(switch (f.kind) {
      IncomingFailureKind.tooLarge => '$name is too large to open.',
      IncomingFailureKind.tooMany => 'Too many files at once. Only the first 20 were received.',
      IncomingFailureKind.noSpace => 'Not enough storage to receive $name.',
      IncomingFailureKind.rejected ||
      IncomingFailureKind.unsupported =>
        'PdfReader can\'t open this kind of link or file.',
      IncomingFailureKind.unreadable => 'Couldn\'t read $name from the other app.',
    });
  }

  static String _openFailureText(OpenFailure failure, String? displayName) {
    final name = displayName ?? 'This file';
    return switch (failure) {
      OpenFailure.notFound => 'Couldn\'t find $name.',
      OpenFailure.tooLarge => '$name is too large to open.',
      OpenFailure.tooManyPages => '$name has too many pages to open.',
      OpenFailure.notPdf => '$name isn\'t a PDF.',
      OpenFailure.corrupted => '$name is damaged and can\'t be opened.',
      OpenFailure.wrongPassword => 'Wrong password for $name.',
      OpenFailure.cancelled => 'Opening $name was cancelled.',
      OpenFailure.timeout => 'Opening $name took too long.',
      OpenFailure.unsafe => '$name looks unsafe or too complex to open.',
    };
  }

  void _snack(String text) {
    if (!mounted) return;
    final ctx = widget.router.routerDelegate.navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
