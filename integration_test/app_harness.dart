import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfreader/app.dart';
import 'package:pdfreader/core/models/app_settings.dart';
import 'package:pdfreader/core/storage/app_storage.dart';
import 'package:pdfrx/pdfrx.dart';

import '../test/helpers/pump_app.dart';
import 'fixtures/corpus_fixtures.g.dart';
import 'keys.dart';

/// Screenshots need `flutter drive` (see integration_test/driver/); plain
/// `flutter test integration_test` skips them.
const qaScreenshots = bool.fromEnvironment('QA_SCREENSHOTS');

IntegrationTestWidgetsFlutterBinding ensureBinding() => IntegrationTestWidgetsFlutterBinding.ensureInitialized();

/// Launches the real app the way main() does, but with a throw-away private
/// directory and fakes for the OS-facing services only (file picker, share
/// sheet, incoming intents). Real Viewer/Editing/Export implementations run.
Future<TestHarness> launchApp(
  WidgetTester tester, {
  bool showOnboarding = false,
  List<String> pdfs = const ['text_multi.pdf'],
  List<Override> overrides = const [],
}) async {
  await pdfrxFlutterInitialize();
  final root = Directory.systemTemp.createTempSync('qa_app_');
  final h = TestHarness(root: root, useFakes: false);
  addTearDown(h.dispose);
  await TempFiles(h.dirs.temp).wipe();
  if (!showOnboarding) h.seedSettings(const AppSettings(onboardingDone: true));
  for (final name in pdfs) {
    final path = h.addPdf(name.split('/').last, corpusFixtures[name]!);
    h.filePick.pickQueue.add([path]);
  }
  await tester.pumpWidget(ProviderScope(
    overrides: h.overrides(extra: overrides),
    child: PdfReaderApp(showOnboarding: showOnboarding),
  ));
  await tester.pump();
  return h;
}

/// Pumps frames until [finder] matches or [timeout] passes. Unlike
/// pumpAndSettle it tolerates spinners and real async work (PDF rendering).
Future<void> pumpUntilFound(WidgetTester tester, Finder finder,
        {Duration timeout = const Duration(seconds: 20)}) =>
    pumpUntilAny(tester, [finder], timeout: timeout);

/// Like [pumpUntilFound] but returns the first of [finders] that matches.
Future<Finder> pumpUntilAny(WidgetTester tester, List<Finder> finders,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    for (final f in finders) {
      if (f.evaluate().isNotEmpty) return f;
    }
  }
  throw TestFailure('Timed out after $timeout waiting for any of $finders');
}

/// Opens the next queued PDF from Home through the (fake) system picker and
/// waits for page 1. Returns the time from tap to page 1 being on screen.
Future<Duration> openFromHome(WidgetTester tester) async {
  await pumpUntilFound(tester, find.byKey(QaKeys.homeOpen));
  final sw = Stopwatch()..start();
  await tester.tap(find.byKey(QaKeys.homeOpen));
  await pumpUntilFound(tester, find.byKey(QaKeys.viewerPage(1)));
  return sw.elapsed;
}

bool _surfaceConverted = false;

Future<void> screenshot(IntegrationTestWidgetsFlutterBinding binding, WidgetTester tester, String name) async {
  if (!qaScreenshots) return;
  if (Platform.isAndroid && !_surfaceConverted) {
    await binding.convertFlutterSurfaceToImage();
    _surfaceConverted = true;
  }
  await tester.pump();
  await binding.takeScreenshot(name);
}
