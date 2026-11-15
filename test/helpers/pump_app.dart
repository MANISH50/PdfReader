import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/app.dart';
import 'package:pdfreader/core/models/app_settings.dart';
import 'package:pdfreader/core/providers.dart';
import 'package:pdfreader/core/storage/app_storage.dart';

import 'fakes.dart';

/// Everything a widget/integration test needs: temp private dirs and a fake
/// for every contract. Pass [useFakes]=false (integration tests) to keep the
/// real feature implementations and fake only the OS-facing services
/// (file picker, share sheet, incoming intents).
class TestHarness {
  TestHarness({Directory? root, this.useFakes = true})
      : dirs = AppDirs(root ?? Directory.systemTemp.createTempSync('pdfreader_test_')) {
    documentService = FakeDocumentService();
    pageEditor = FakePageEditor();
    saveService = FakeSaveService(dirs.drafts);
    exporter = FakeExporter(dirs.temp);
  }

  final AppDirs dirs;
  final bool useFakes;
  late final FakeDocumentService documentService;
  late final FakePageEditor pageEditor;
  late final FakeSaveService saveService;
  late final FakeExporter exporter;
  final incoming = FakeIncomingFileService();
  final share = FakeShareService();
  final filePick = FakeFilePickService();

  /// Writes settings where SettingsNotifier and main() read them.
  void seedSettings(AppSettings s) =>
      File('${dirs.data.path}/settings.json').writeAsStringSync(jsonEncode(s.toJson()));

  /// Copies a PDF into app-private inbox storage (as the app would after an
  /// open-with) and returns the new path.
  String addPdf(String name, List<int> bytes) {
    final f = File('${dirs.inbox.path}/$name')..writeAsBytesSync(bytes, flush: true);
    return f.path;
  }

  List<Override> overrides({AppSettings? settings, List<Override> extra = const []}) => [
        appDirsProvider.overrideWithValue(dirs),
        if (settings != null) settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
        if (useFakes) ...[
          documentServiceProvider.overrideWithValue(documentService),
          pageEditorProvider.overrideWithValue(pageEditor),
          saveServiceProvider.overrideWithValue(saveService),
          exportersProvider.overrideWithValue([exporter]),
        ],
        incomingFileServiceProvider.overrideWithValue(incoming),
        shareServiceProvider.overrideWithValue(share),
        filePickServiceProvider.overrideWithValue(filePick),
        ...extra,
      ];

  void dispose() {
    incoming.close();
    try {
      dirs.root.deleteSync(recursive: true);
    } on FileSystemException {
      // best effort
    }
  }
}

/// In-memory settings (no file I/O, so it resolves inside fake-async widget tests).
class FixedSettingsNotifier extends SettingsNotifier {
  FixedSettingsNotifier(this.initial);
  final AppSettings initial;

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<void> change(AppSettings Function(AppSettings) f) async {
    state = AsyncData(f(state.value ?? initial));
  }
}

/// Pumps the whole app with [harness] overrides. Settings default to
/// "onboarding done" so tests land on Home unless [showOnboarding] is true.
Future<TestHarness> pumpApp(
  WidgetTester tester, {
  TestHarness? harness,
  bool showOnboarding = false,
  AppSettings? settings,
  List<Override> overrides = const [],
  bool settle = true,
}) async {
  final h = harness ?? TestHarness();
  addTearDown(h.dispose);
  final s = settings ?? AppSettings(onboardingDone: !showOnboarding);
  await tester.pumpWidget(ProviderScope(
    overrides: h.overrides(settings: s, extra: overrides),
    child: PdfReaderApp(showOnboarding: showOnboarding),
  ));
  if (settle) await tester.pumpAndSettle();
  return h;
}
