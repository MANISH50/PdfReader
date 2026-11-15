// Scroll performance and first-page time.
//
// Accurate numbers need profile mode via flutter drive (see TESTING.md):
//   flutter drive --profile --driver=integration_test/driver/perf_driver.dart \
//     --target=integration_test/performance_test.dart [--dart-define=QA_HUGE=true]
// Results: build/integration_response_data.json and build/perf_summary.txt.
// Thresholds are asserted only with --dart-define=QA_ENFORCE_PERF=true
// (emulators without GPU acceleration cannot hit 60 fps).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/helpers/huge_pdf_writer.dart';
import 'app_harness.dart';
import 'keys.dart';

const enforce = bool.fromEnvironment('QA_ENFORCE_PERF');
const withHuge = bool.fromEnvironment('QA_HUGE');

/// Target: 60 fps -> 90th-percentile frame build and raster time < 16 ms.
const frameBudgetMs = 16.0;
const firstPageBudget = Duration(seconds: 2);

void main() {
  final binding = ensureBinding();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> scrollThrough(WidgetTester tester, {int flings = 8}) async {
    final scroll = find.byKey(QaKeys.viewerScroll);
    for (var i = 0; i < flings; i++) {
      await tester.fling(scroll, const Offset(0, -900), 4000);
      await tester.pumpAndSettle(const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 20));
    }
    for (var i = 0; i < flings ~/ 2; i++) {
      await tester.fling(scroll, const Offset(0, 1400), 5000);
      await tester.pumpAndSettle(const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 20));
    }
  }

  void report(String key, Duration firstPage) {
    final data = binding.reportData ??= <String, dynamic>{};
    data['${key}_first_page_ms'] = firstPage.inMilliseconds;
    final s = (data[key] as Map?)?.cast<String, dynamic>() ?? const {};
    final build90 = (s['90th_percentile_frame_build_time_millis'] as num?)?.toDouble() ?? -1;
    final raster90 = (s['90th_percentile_frame_rasterizer_time_millis'] as num?)?.toDouble() ?? -1;
    final line = 'PERF $key: firstPage=${firstPage.inMilliseconds}ms frames=${s['frame_count']} '
        'build p90=${build90}ms raster p90=${raster90}ms '
        'missedBuild=${s['missed_frame_build_budget_count']} missedRaster=${s['missed_frame_rasterizer_budget_count']}';
    debugPrint(line);
    ((data['summary_lines'] ??= <String>[]) as List).add(line);
    if (enforce) {
      expect(firstPage, lessThan(firstPageBudget), reason: 'first page must show in < 2 s');
      expect(build90, lessThan(frameBudgetMs), reason: '90th percentile build time');
      expect(raster90, lessThan(frameBudgetMs), reason: '90th percentile raster time');
    }
  }

  testWidgets('text_multi.pdf: first page + scrolling', (tester) async {
    await launchApp(tester);
    final firstPage = await openFromHome(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10));
    await binding.watchPerformance(() => scrollThrough(tester), reportKey: 'text_multi_scroll');
    report('text_multi_scroll', firstPage);
    await screenshot(binding, tester, 'perf_text_multi');
  });

  testWidgets('huge.pdf (1200 pages, 100+ MB): first page + scrolling', (tester) async {
    final dir = Directory.systemTemp.createTempSync('qa_huge_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sw = Stopwatch()..start();
    final huge = await tester.runAsync(() => writeHugePdf('${dir.path}/huge.pdf'));
    debugPrint('PERF huge.pdf generated on device in ${sw.elapsed.inSeconds}s '
        '(${(huge!.lengthSync() / 1e6).toStringAsFixed(0)} MB)');
    final h = await launchApp(tester, pdfs: const []);
    h.filePick.pickQueue.add([huge.path]);
    final firstPage = await openFromHome(tester);
    await binding.watchPerformance(() => scrollThrough(tester, flings: 12), reportKey: 'huge_scroll');
    report('huge_scroll', firstPage);
  }, skip: !withHuge);
}
