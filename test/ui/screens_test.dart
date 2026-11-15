import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/app_router.dart';
import 'package:pdfreader/core/models/app_settings.dart';
import 'package:pdfreader/core/models/reading_state.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/features/library/open_document.dart';

import 'helpers.dart';

void main() {
  group('HomeScreen', () {
    testWidgets('empty state offers Open PDF which imports and opens the viewer', (tester) async {
      final h = Harness(picker: FakePicker(['/picked/Paper.pdf']));
      await h.pump(tester, Routes.home);
      expect(find.text('Your library is empty'), findsOneWidget);
      await tester.tap(find.text('Open PDF'));
      await tester.pumpAndSettle();
      expect(find.text('viewer:Paper.pdf'), findsOneWidget);
      // Recorded in recents.
      final recents = h.store.data['recents']! as List;
      expect(recents, hasLength(1));
    });

    testWidgets('cancelled picker does nothing', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.home);
      await tester.tap(find.text('Open PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Your library is empty'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('import failure shows a friendly snackbar', (tester) async {
      final h = Harness(
        picker: FakePicker(['/picked/bad.pdf']),
        documents: FakeDocumentService(fail: OpenFailure.corrupted),
      );
      await h.pump(tester, Routes.home);
      await tester.tap(find.text('Open PDF'));
      await tester.pump();
      expect(find.text(friendlyOpenError(const DocumentOpenException(OpenFailure.corrupted))), findsOneWidget);
    });

    testWidgets('lists recents, filters by search, prunes missing files', (tester) async {
      final h = Harness(exists: (p) => !p.endsWith('Gone.pdf'));
      seedRecents(h.store, [doc('Alpha.pdf'), doc('Gone.pdf'), doc('Beta notes.pdf')], states: {
        'id_Alpha.pdf': ReadingState(pageNumber: 7, lastOpened: DateTime.now()),
      });
      await h.pump(tester, Routes.home);
      expect(find.text('Alpha.pdf'), findsOneWidget);
      expect(find.text('Beta notes.pdf'), findsOneWidget);
      expect(find.text('Gone.pdf'), findsNothing);
      expect((h.store.data['recents']! as List), hasLength(2));
      expect(find.text('Page 7'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'beta');
      await tester.pumpAndSettle();
      expect(find.text('Alpha.pdf'), findsNothing);
      expect(find.text('Beta notes.pdf'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
    });

    testWidgets('remove from recents via menu, then undo', (tester) async {
      final h = Harness();
      seedRecents(h.store, [doc('Alpha.pdf'), doc('Beta.pdf')]);
      await h.pump(tester, Routes.home);
      await tester.tap(find.byTooltip('More options for Alpha.pdf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from recents'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha.pdf'), findsNothing);
      expect((h.store.data['recents']! as List), hasLength(1));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha.pdf'), findsOneWidget);
      final names = [for (final e in h.store.data['recents']! as List) (e as Map)['displayName']];
      expect(names, ['Alpha.pdf', 'Beta.pdf']);
    });

    testWidgets('swipe removes from recents', (tester) async {
      final h = Harness();
      seedRecents(h.store, [doc('Alpha.pdf'), doc('Beta.pdf')]);
      await h.pump(tester, Routes.home);
      await tester.drag(find.text('Alpha.pdf'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Alpha.pdf'), findsNothing);
    });

    testWidgets('tapping a recent opens it', (tester) async {
      final h = Harness();
      seedRecents(h.store, [doc('Alpha.pdf')]);
      await h.pump(tester, Routes.home);
      await tester.tap(find.text('Alpha.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('viewer:Alpha.pdf'), findsOneWidget);
    });

    testWidgets('tablet shows a grid of cards', (tester) async {
      final h = Harness();
      seedRecents(h.store, [doc('Alpha.pdf'), doc('Beta.pdf')]);
      await h.pump(tester, Routes.home, size: const Size(1024, 1366));
      expect(find.byType(SliverGrid), findsOneWidget);
    });

    testWidgets('merge needs two files, then opens the organize flow', (tester) async {
      final h = Harness(picker: FakePicker(['/p/One.pdf']));
      seedRecents(h.store, [doc('Alpha.pdf')]);
      await h.pump(tester, Routes.home);
      await tester.tap(find.byTooltip('Merge PDFs'));
      await tester.pump();
      expect(h.picker.lastMultiple, isTrue);
      expect(find.text('Choose at least two PDFs to merge.'), findsOneWidget);
      await tester.pumpAndSettle();
      h.picker.result = ['/p/One.pdf', '/p/Two.pdf'];
      await tester.tap(find.byTooltip('Merge PDFs'));
      await tester.pumpAndSettle();
      expect(find.text('organize:One.pdf'), findsOneWidget);
    });

    testWidgets('settings button navigates', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.home);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
    });
  });

  group('OnboardingScreen', () {
    testWidgets('swipe through and finish marks onboarding done', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.onboarding);
      expect(find.text('Your PDFs, private by design'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('Made for reading'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Always'), findsWidgets); // Android steps
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(AppSettings.fromJson(h.store.data['settings']! as Map<String, Object?>).onboardingDone, isTrue);
      expect(find.text('Library'), findsWidgets);
    });

    testWidgets('skip finishes immediately', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.onboarding);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsWidgets);
    });

    testWidgets('iOS shows the Share-sheet steps and the default-app caveat', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.onboarding, platform: TargetPlatform.iOS);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('system-wide default'), findsOneWidget);
    });
  });

  group('SettingsScreen', () {
    testWidgets('changes app theme, page theme, reading mode and keep-screen-on', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.settings);
      AppSettings saved() => AppSettings.fromJson(h.store.data['settings']! as Map<String, Object?>);

      await tester.tap(find.text('Dark').first);
      await tester.pumpAndSettle();
      expect(saved().themeMode, AppThemeMode.dark);

      await tester.tap(find.bySemanticsLabel('Sepia page theme'));
      await tester.pumpAndSettle();
      expect(saved().defaultPageTheme, PageTheme.sepia);

      await tester.tap(find.text('Default reading mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Two-page spread'));
      await tester.pumpAndSettle();
      expect(saved().defaultReadingMode, ReadingMode.twoPage);

      await tester.tap(find.text('Keep screen on'));
      await tester.pumpAndSettle();
      expect(saved().keepScreenOn, isFalse);
    });

    testWidgets('clear recents asks first; clear temp wipes', (tester) async {
      final h = Harness();
      seedRecents(h.store, [doc('A.pdf')]);
      await h.pump(tester, Routes.settings);
      await tester.scrollUntilVisible(find.text('Clear recent files'), 200);
      await tester.tap(find.text('Clear recent files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(h.store.data.containsKey('recents'), isFalse);

      await tester.tap(find.text('Clear temporary files'));
      await tester.pumpAndSettle();
      expect(h.temp.wipes, 1);
    });

    testWidgets('default-app guide opens from settings', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.settings);
      await tester.scrollUntilVisible(find.text('How to open PDFs with PdfReader'), 200);
      await tester.tap(find.text('How to open PDFs with PdfReader'));
      await tester.pumpAndSettle();
      expect(find.text('Make PdfReader your PDF app'), findsOneWidget);
    });

    testWidgets('licenses page opens', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.settings);
      await tester.scrollUntilVisible(find.text('Open-source licenses'), 200);
      await tester.tap(find.text('Open-source licenses'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LicensePage), findsOneWidget);
    });
  });

  group('Accessibility guidelines', () {
    for (final (name, route) in [
      ('home', Routes.home),
      ('settings', Routes.settings),
      ('onboarding', Routes.onboarding),
    ]) {
      testWidgets('$name meets tap-target, label and contrast guidelines', (tester) async {
        final handle = tester.ensureSemantics();
        final h = Harness();
        if (route == Routes.home) seedRecents(h.store, [doc('Alpha.pdf'), doc('Beta.pdf')]);
        await h.pump(tester, route);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    }
  });

  group('QA integration-test keys', () {
    testWidgets('home, onboarding and settings expose the agreed keys', (tester) async {
      final h = Harness();
      await h.pump(tester, Routes.home);
      expect(find.byKey(const Key('home.screen')), findsOneWidget);
      expect(find.byKey(const Key('home.open')), findsOneWidget);
      expect(find.byKey(const Key('home.settings')), findsOneWidget);

      seedRecents(h.store, [doc('A.pdf'), doc('B.pdf')]);
      await h.pump(tester, Routes.home);
      expect(find.byKey(const Key('home.recent.0')), findsOneWidget);
      expect(find.byKey(const Key('home.recent.1')), findsOneWidget);
      expect(find.byKey(const Key('home.open')), findsOneWidget); // FAB

      await h.pump(tester, Routes.onboarding);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('onboarding.next')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('onboarding.done')), findsOneWidget);

      await h.pump(tester, Routes.settings);
      await tester.tap(find.byKey(const Key('settings.theme.dark')));
      await tester.pumpAndSettle();
      expect(AppSettings.fromJson(h.store.data['settings']! as Map<String, Object?>).themeMode, AppThemeMode.dark);
      expect(find.byKey(const Key('settings.theme.light')), findsOneWidget);
      expect(find.byKey(const Key('settings.theme.system')), findsOneWidget);
    });
  });
}
