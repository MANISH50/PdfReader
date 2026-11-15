// End-to-end flows on a real device/simulator:
//   flutter test integration_test/app_flow_test.dart -d <device>
// Keys are listed in integration_test/keys.dart and TESTING.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'app_harness.dart';
import 'keys.dart';

void main() {
  final binding = ensureBinding();

  testWidgets('first launch: onboarding -> home', (tester) async {
    await launchApp(tester, showOnboarding: true);
    await pumpUntilAny(tester, [
      find.byKey(QaKeys.onboardingDone).hitTestable(),
      find.byKey(QaKeys.onboardingNext).hitTestable(),
    ]);
    await screenshot(binding, tester, '01_onboarding');
    for (var i = 0; i < 10 && find.byKey(QaKeys.onboardingDone).hitTestable().evaluate().isEmpty; i++) {
      await tester.tap(find.byKey(QaKeys.onboardingNext));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(QaKeys.onboardingDone));
    await pumpUntilFound(tester, find.byKey(QaKeys.homeScreen));
    await screenshot(binding, tester, '02_home');
  });

  testWidgets('open bundled PDF, navigate pages, search', (tester) async {
    await launchApp(tester);
    final firstPage = await openFromHome(tester);
    debugPrint('PERF first page (flow): ${firstPage.inMilliseconds} ms');
    await screenshot(binding, tester, '03_viewer');

    // Go to page 5.
    await tester.tap(find.byKey(QaKeys.viewerGoToPage));
    await pumpUntilFound(tester, find.byKey(QaKeys.viewerGoToPageField));
    await tester.enterText(find.byKey(QaKeys.viewerGoToPageField), '5');
    await tester.tap(find.byKey(QaKeys.viewerGoToPageOk));
    await pumpUntilFound(tester, find.byKey(QaKeys.viewerPage(5)));
    await pumpUntilFound(tester, find.descendant(
        of: find.byKey(QaKeys.viewerPageIndicator), matching: find.textContaining('5')));

    // Search: "needle" is on pages 3, 11 and 18 (manifest.json).
    await tester.tap(find.byKey(QaKeys.viewerSearch));
    await pumpUntilFound(tester, find.byKey(QaKeys.viewerSearchField));
    await tester.enterText(find.byKey(QaKeys.viewerSearchField), 'needle');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntilFound(tester, find.descendant(
        of: find.byKey(QaKeys.viewerSearchCount), matching: find.textContaining('3')));
    await tester.tap(find.byKey(QaKeys.viewerSearchNext));
    await pumpUntilFound(tester, find.byKey(QaKeys.viewerPage(11)));
    await screenshot(binding, tester, '04_search');
  });

  testWidgets('theme switch to dark and back', (tester) async {
    await launchApp(tester);
    await pumpUntilFound(tester, find.byKey(QaKeys.homeSettings));
    await tester.tap(find.byKey(QaKeys.homeSettings));
    await pumpUntilFound(tester, find.byKey(QaKeys.settingsThemeDark));
    await tester.tap(find.byKey(QaKeys.settingsThemeDark));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.byKey(QaKeys.settingsThemeDark));
    expect(Theme.of(ctx).brightness, Brightness.dark);
    await screenshot(binding, tester, '05_settings_dark');
    await tester.tap(find.byKey(QaKeys.settingsThemeLight));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byKey(QaKeys.settingsThemeLight))).brightness, Brightness.light);
  });

  testWidgets('export TXT', (tester) async {
    final h = await launchApp(tester);
    await openFromHome(tester);
    await tester.tap(find.byKey(QaKeys.viewerMenu));
    await pumpUntilFound(tester, find.byKey(QaKeys.viewerExport));
    await tester.tap(find.byKey(QaKeys.viewerExport));
    await pumpUntilFound(tester, find.byKey(QaKeys.exportFormat('txt')));
    await tester.tap(find.byKey(QaKeys.exportFormat('txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(QaKeys.exportStart));
    await tester.pump(const Duration(milliseconds: 300));
    if (find.byKey(QaKeys.exportConfirmLossy).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(QaKeys.exportConfirmLossy));
    }
    await pumpUntilAny(tester, [find.byKey(QaKeys.exportShare), find.byKey(QaKeys.exportDone)],
        timeout: const Duration(seconds: 60));
    await screenshot(binding, tester, '06_export_done');
    if (find.byKey(QaKeys.exportShare).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(QaKeys.exportShare));
      await tester.pumpAndSettle();
    }
    // The TXT must exist in app-private storage (or have gone to the share sheet).
    final txt = [
      ...h.share.shared.expand((s) => s.paths),
      ...h.dirs.root.listSync(recursive: true).whereType<File>().map((f) => f.path),
    ].where((p) => p.endsWith('.txt')).toList();
    expect(txt, isNotEmpty, reason: 'export produced no .txt');
    final text = File(txt.first).existsSync() ? File(txt.first).readAsStringSync() : '';
    expect(text, contains('Chapter 1'));
    expect(text, contains('needle'));
  });
}
