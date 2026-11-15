import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/core/storage/stores.dart';
import 'package:pdfreader/platform/incoming_file_service_impl.dart';
import 'package:pdfreader/platform/incoming_router.dart';
import 'package:pdfreader/platform/platform_services.dart';
import 'package:pdfrx/pdfrx.dart';

class _FakeIncoming implements IncomingFileService, IncomingFailureSource {
  IncomingFile? initial;
  // ignore: close_sinks (closed in tearDown)
  final controller = StreamController<IncomingFile>();
  // ignore: close_sinks (closed in tearDown)
  final failureController = StreamController<IncomingFailure>.broadcast();
  @override
  Future<IncomingFile?> initialFile() async => initial;
  @override
  Stream<IncomingFile> get files => controller.stream;
  @override
  Stream<IncomingFailure> get failures => failureController.stream;
}

class _FakeDocs implements DocumentService {
  final imported = <String>[];
  @override
  Future<DocumentRef> importFile(String path, {String? displayName, String? sourceUri}) async {
    if (path.endsWith('bad.pdf')) throw const DocumentOpenException(OpenFailure.notPdf);
    imported.add(path);
    return DocumentRef(id: path, path: path, displayName: displayName ?? path, sizeBytes: 1);
  }

  @override
  Future<PdfDocument> open(DocumentRef ref, {PasswordRequest? askPassword}) => throw UnimplementedError();
}

class _FakeRecents extends RecentFilesStore {
  _FakeRecents(Directory dir) : super(JsonStore(dir));
  final touched = <String>[];
  @override
  Future<void> touch(DocumentRef ref) async => touched.add(ref.path);
}

void main() {
  late Directory tmp;
  late _FakeIncoming incoming;
  late _FakeDocs docs;
  late _FakeRecents recents;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('router_test');
    incoming = _FakeIncoming();
    docs = _FakeDocs();
    recents = _FakeRecents(tmp);
  });
  tearDown(() async {
    await incoming.controller.close();
    await incoming.failureController.close();
    tmp.deleteSync(recursive: true);
  });

  Future<GoRouter> pumpApp(WidgetTester tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(
        path: '/viewer',
        builder: (_, s) => Scaffold(body: Text('viewer ${(s.extra! as DocumentRef).displayName}')),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDirsProvider.overrideWithValue(AppDirs(tmp)),
        incomingFileServiceProvider.overrideWithValue(incoming),
        documentServiceProvider.overrideWithValue(docs),
        recentFilesStoreProvider.overrideWithValue(recents),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => IncomingFileListener(router: router, child: child!),
      ),
    ));
    return router;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('cold-start file opens the viewer', (tester) async {
    incoming.initial = const IncomingFile(path: '/inbox/a.pdf', displayName: 'a.pdf');
    await pumpApp(tester);
    await settle(tester);
    expect(docs.imported, ['/inbox/a.pdf']);
    expect(find.text('viewer a.pdf'), findsOneWidget);
  });

  testWidgets('file while running opens the viewer; batch extras go to recents', (tester) async {
    await pumpApp(tester);
    await settle(tester);
    expect(find.text('home'), findsOneWidget);
    incoming.controller
      ..add(const IncomingFile(path: '/inbox/b.pdf', displayName: 'b.pdf'))
      ..add(const IncomingFile(path: '/inbox/c.pdf', displayName: 'c.pdf'));
    await settle(tester);
    expect(find.text('viewer b.pdf'), findsOneWidget);
    expect(find.text('viewer c.pdf'), findsNothing);
    expect(docs.imported, ['/inbox/b.pdf', '/inbox/c.pdf']);
    expect(recents.touched, ['/inbox/c.pdf']);
    expect(find.text('1 more file added to Recent files.'), findsOneWidget);
  });

  testWidgets('import and receive failures show a message', (tester) async {
    await pumpApp(tester);
    await settle(tester);
    incoming.controller.add(const IncomingFile(path: '/inbox/bad.pdf', displayName: 'bad.pdf'));
    await settle(tester);
    expect(find.text('bad.pdf isn\'t a PDF.'), findsOneWidget);
    expect(find.text('home'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    incoming.failureController.add(
        const IncomingFailure(IncomingFailureKind.tooLarge, displayName: 'huge.pdf'));
    await settle(tester);
    expect(find.text('huge.pdf is too large to open.'), findsOneWidget);
  });
}
