import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/app_router.dart';
import 'package:pdfreader/core/models/reading_state.dart';

import 'helpers.dart';

/// Golden-free layout checks: every main screen at phone and tablet sizes,
/// both orientations, text scale 1.0 and 2.0, must lay out without overflow.
void main() {
  for (final MapEntry(key: name, value: size) in layoutSizes.entries) {
    for (final scale in textScales) {
      final tag = '$name @${scale}x';

      testWidgets('home (empty) — $tag', (tester) async {
        final h = Harness();
        await h.pump(tester, Routes.home, size: size, textScale: scale);
        expect(find.text('Your library is empty'), findsOneWidget);
        await scrollThroughAndExpectNoOverflow(tester);
      });

      testWidgets('home (recents) — $tag', (tester) async {
        final h = Harness();
        final docs = [
          for (var i = 0; i < 8; i++)
            doc(i == 0
                ? 'A very long document name that goes on and on for quite a while.pdf'
                : 'Report $i.pdf'),
        ];
        seedRecents(h.store, docs, states: {
          docs[0].id: ReadingState(pageNumber: 12, lastOpened: DateTime(2026, 3, 1)),
          docs[1].id: ReadingState(pageNumber: 3, lastOpened: DateTime.now()),
        });
        await h.pump(tester, Routes.home, size: size, textScale: scale);
        expect(find.textContaining('Report 1'), findsWidgets);
        await scrollThroughAndExpectNoOverflow(tester);
      });

      testWidgets('settings — $tag', (tester) async {
        final h = Harness();
        await h.pump(tester, Routes.settings, size: size, textScale: scale);
        await scrollThroughAndExpectNoOverflow(tester);
        expect(find.text('Open-source licenses'), findsOneWidget);
      });

      testWidgets('onboarding (all pages) — $tag', (tester) async {
        final h = Harness();
        await h.pump(tester, Routes.onboarding, size: size, textScale: scale);
        for (var page = 0; page < 4; page++) {
          await scrollThroughAndExpectNoOverflow(tester);
          if (page < 3) {
            await tester.tap(find.text('Continue'));
            await tester.pumpAndSettle();
          }
        }
        expect(find.text('Get started'), findsOneWidget);
      });

      testWidgets('home on iOS — $tag', (tester) async {
        final h = Harness();
        seedRecents(h.store, [doc('One.pdf'), doc('Two.pdf')]);
        await h.pump(tester, Routes.home, size: size, textScale: scale, platform: TargetPlatform.iOS);
        await scrollThroughAndExpectNoOverflow(tester);
      });
    }
  }

  testWidgets('settings on iOS in dark mode lays out', (tester) async {
    final h = Harness();
    await h.pump(tester, Routes.settings,
        textScale: 2, platform: TargetPlatform.iOS, brightness: Brightness.dark);
    await scrollThroughAndExpectNoOverflow(tester);
  });
}
