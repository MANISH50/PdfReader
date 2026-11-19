import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/app_router.dart';
import 'package:pdfreader/core/models/document_ref.dart';
import 'package:pdfreader/core/models/reading_state.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfreader/features/library/home_screen.dart';
import 'package:pdfreader/features/library/recents_controller.dart';
import 'package:pdfreader/features/onboarding/onboarding_screen.dart';
import 'package:pdfreader/features/settings/settings_screen.dart';
import 'package:pdfreader/platform/platform_services.dart';
import 'package:pdfreader/ui/design_system/app_theme.dart';
import 'package:pdfrx/pdfrx.dart';

/// In-memory JsonStore (no real IO, so it works inside fake async).
class MemoryJsonStore implements JsonStore {
  final Map<String, Object?> data = {};
  @override
  Directory get dir => Directory.systemTemp;
  @override
  Future<Object?> read(String key) async => data[key];
  @override
  Future<void> write(String key, Object? value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class FakeTempFiles implements TempFiles {
  int wipes = 0;
  @override
  Directory get dir => Directory.systemTemp;
  @override
  File create(String extension) => throw UnimplementedError();
  @override
  Directory createDir() => throw UnimplementedError();
  @override
  Future<void> wipe() async => wipes++;
}

class FakePicker implements FilePickService {
  FakePicker(this.result);
  List<String> result;
  bool? lastMultiple;
  @override
  Future<List<String>> pickPdfs({bool multiple = false}) async {
    lastMultiple = multiple;
    return result;
  }

  @override
  Future<List<String>> pickDocuments() async => result;

  @override
  Future<String?> saveAs(String sourcePath, {required String suggestedName}) async => null;
}

class FakeDocumentService implements DocumentService {
  FakeDocumentService({this.fail});
  final OpenFailure? fail;
  @override
  Future<DocumentRef> importFile(String path, {String? displayName, String? sourceUri}) async {
    if (fail != null) throw DocumentOpenException(fail!);
    return doc(path.split('/').last);
  }

  @override
  Future<PdfDocument> open(DocumentRef ref, {PasswordRequest? askPassword}) => throw UnimplementedError();
}

DocumentRef doc(String name, {int size = 1234567}) =>
    DocumentRef(id: 'id_$name', path: '/docs/$name', displayName: name, sizeBytes: size);

/// Seeds [store] with recents (newest first) and optional reading states.
void seedRecents(MemoryJsonStore store, List<DocumentRef> docs, {Map<String, ReadingState> states = const {}}) {
  store.data['recents'] = [for (final d in docs) d.toJson()];
  for (final e in states.entries) {
    store.data['state_${e.key}'] = e.value.toJson();
  }
}

class Harness {
  Harness({
    MemoryJsonStore? store,
    FakePicker? picker,
    DocumentService? documents,
    this.exists,
  })  : store = store ?? MemoryJsonStore(),
        picker = picker ?? FakePicker(const []),
        documents = documents ?? FakeDocumentService();

  final MemoryJsonStore store;
  final FakePicker picker;
  final DocumentService documents;
  final FakeTempFiles temp = FakeTempFiles();
  final bool Function(String)? exists;

  List<Override> get overrides => [
        jsonStoreProvider.overrideWithValue(store),
        tempFilesProvider.overrideWithValue(temp),
        filePickServiceProvider.overrideWithValue(picker),
        documentServiceProvider.overrideWithValue(documents),
        fileExistsProvider.overrideWithValue(exists ?? (_) => true),
      ];

  GoRouter router(String initial) => GoRouter(
        initialLocation: initial,
        routes: [
          GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
          GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingScreen()),
          GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
          GoRoute(
            path: Routes.viewer,
            builder: (_, s) => Scaffold(body: Text('viewer:${(s.extra! as DocumentRef).displayName}')),
          ),
          GoRoute(
            path: Routes.organize,
            builder: (_, s) => Scaffold(body: Text('organize:${(s.extra! as DocumentRef).displayName}')),
          ),
        ],
      );

  Future<void> pump(
    WidgetTester tester,
    String location, {
    Size size = const Size(360, 780),
    double textScale = 1.0,
    TargetPlatform platform = TargetPlatform.android,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final theme = (brightness == Brightness.light ? AppTheme.light() : AppTheme.dark()).copyWith(platform: platform);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(theme: theme, routerConfig: router(location)),
    ));
    await tester.pumpAndSettle();
  }
}

const layoutSizes = <String, Size>{
  'phone portrait': Size(360, 780),
  'phone landscape': Size(780, 360),
  'tablet portrait': Size(1024, 1366),
  'tablet landscape': Size(1366, 1024),
};

const textScales = [1.0, 2.0];

/// Scrolls the first scrollable to the end, asserting no layout exceptions
/// (overflow errors surface through [WidgetTester.takeException]).
Future<void> scrollThroughAndExpectNoOverflow(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 30; i++) {
    final state = tester.state<ScrollableState>(scrollable);
    final pos = state.position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }
}
