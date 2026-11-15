import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfreader/features/onboarding/default_app_steps.dart';
import 'package:pdfreader/ui/design_system/design_system.dart';

void main() {
  group('WCAG contrast', () {
    test('ratio helper matches known values', () {
      expect(Contrast.ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
      expect(Contrast.ratio(const Color(0xFF777777), const Color(0xFFFFFFFF)), closeTo(4.48, 0.02));
    });

    test('brand seed is AA on white', () {
      expect(Contrast.ratio(Brand.seed, const Color(0xFFFFFFFF)), greaterThanOrEqualTo(Contrast.aa));
    });

    for (final b in Brightness.values) {
      for (final hc in [false, true]) {
        test('key pairs pass AA — ${b.name}${hc ? ' high contrast' : ''}', () {
          final s = AppTheme.scheme(b, highContrast: hc);
          final min = hc ? Contrast.aaa : Contrast.aa;
          final pairs = <String, (Color, Color)>{
            'onSurface/surface': (s.onSurface, s.surface),
            'onSurfaceVariant/surface': (s.onSurfaceVariant, s.surface),
            'onSurfaceVariant/surfaceContainerLow': (s.onSurfaceVariant, s.surfaceContainerLow),
            'onSurfaceVariant/surfaceContainerHigh': (s.onSurfaceVariant, s.surfaceContainerHigh),
            'primary/surface': (s.primary, s.surface),
            'onPrimary/primary': (s.onPrimary, s.primary),
            'onPrimaryContainer/primaryContainer': (s.onPrimaryContainer, s.primaryContainer),
            'onSecondaryContainer/secondaryContainer': (s.onSecondaryContainer, s.secondaryContainer),
            'onErrorContainer/errorContainer': (s.onErrorContainer, s.errorContainer),
            'onError/error': (s.onError, s.error),
            'onInverseSurface/inverseSurface': (s.onInverseSurface, s.inverseSurface),
          };
          for (final MapEntry(key: name, value: (fg, bg)) in pairs.entries) {
            // Non-high-contrast still must meet AA; high contrast aims for AAA
            // on the main text pairs and at least AA elsewhere.
            final need = name.startsWith('onSurface/') ? min : Contrast.aa;
            expect(Contrast.ratio(fg, bg), greaterThanOrEqualTo(need), reason: '$name ${b.name} hc=$hc');
          }
        });
      }
    }
  });

  group('formatters', () {
    test('formatBytes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(1234567), '1.2 MB');
      expect(formatBytes(300 * 1024 * 1024), '300 MB');
    });

    test('formatLastOpened', () {
      final now = DateTime(2026, 11, 15, 12);
      expect(formatLastOpened(now, now: now), 'Just now');
      expect(formatLastOpened(DateTime(2026, 11, 15, 8), now: now), 'Today');
      expect(formatLastOpened(DateTime(2026, 11, 14, 23), now: now), 'Yesterday');
      expect(formatLastOpened(DateTime(2026, 11, 11), now: now), '4 days ago');
      expect(formatLastOpened(DateTime(2026, 3, 2), now: now), '2 Mar 2026');
    });

    test('tile data labels', () {
      const d = DocumentTileData(id: 'x', name: 'a.pdf', sizeBytes: 2048, page: 3, pageCount: 12);
      expect(d.pageLabel, 'Page 3 of 12');
      expect(d.progress, closeTo(0.25, 1e-9));
      expect(const DocumentTileData(id: 'x', name: 'a', sizeBytes: 1, page: 4).progress, isNull);
    });
  });

  test('default-app guide per platform', () {
    expect(defaultAppGuideFor(TargetPlatform.android).steps.join(), contains('Always'));
    expect(defaultAppGuideFor(TargetPlatform.iOS).note, contains('default'));
    expect(defaultAppGuideFor(TargetPlatform.linux).steps, isNotEmpty);
  });

  Widget wrap(Widget child, {bool reduceMotion = false}) => MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('FadeSlideIn shows content immediately with reduced motion', (tester) async {
    await tester.pumpWidget(wrap(const FadeSlideIn(child: Text('hi')), reduceMotion: true));
    final fade = tester.widget<FadeTransition>(
        find.ancestor(of: find.text('hi'), matching: find.byType(FadeTransition)).first);
    expect(fade.opacity.value, 1);
  });

  testWidgets('FadeSlideIn animates in otherwise', (tester) async {
    await tester.pumpWidget(wrap(FadeSlideIn.staggered(index: 3, child: const Text('hi'))));
    final fade = tester.widget<FadeTransition>(
        find.ancestor(of: find.text('hi'), matching: find.byType(FadeTransition)).first);
    expect(fade.opacity.value, 0);
    await tester.pumpAndSettle();
    expect(fade.opacity.value, 1);
  });

  testWidgets('Motion.of honours reduce motion', (tester) async {
    late Duration d;
    await tester.pumpWidget(wrap(Builder(builder: (c) {
      d = Motion.of(c, Motion.slow);
      return const SizedBox();
    }), reduceMotion: true));
    expect(d, Duration.zero);
  });

  testWidgets('PrimaryButton busy state disables and shows progress', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(PrimaryButton(label: 'Go', busy: true, onPressed: () => taps++)));
    await tester.tap(find.text('Go'));
    expect(taps, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('DocumentTile exposes one semantic button with full label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(DocumentTile(
      data: const DocumentTileData(id: 'a', name: 'Doc.pdf', sizeBytes: 2048, page: 2, pageCount: 4),
      onTap: () {},
    )));
    expect(find.bySemanticsLabel(RegExp(r'Doc\.pdf, 2 KB, Page 2 of 4')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    handle.dispose();
  });

  testWidgets('AppLogo and bottom sheet with drag handle render', (tester) async {
    await tester.pumpWidget(wrap(Builder(
      builder: (c) => TextButton(
        onPressed: () => showAppBottomSheet<void>(c, title: 'Sheet', builder: (_) => const AppLogo(size: 64)),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet'), findsOneWidget);
    expect(find.byType(AppLogo), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Dismiss')), findsWidgets);
  });
}
