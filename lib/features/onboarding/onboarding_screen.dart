import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app_router.dart';
import '../../core/providers.dart';
import '../../ui/design_system/design_system.dart';
import 'default_app_guide_view.dart';

/// First-launch walkthrough: privacy, reading, tools, default-app setup.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pages = PageController();
  int _index = 0;
  bool _finishing = false;

  static const _count = 4;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  bool get _isLast => _index == _count - 1;

  Future<void> _next() async {
    if (_isLast) return _finish();
    final d = Motion.of(context, Motion.slow);
    if (d == Duration.zero) {
      _pages.jumpToPage(_index + 1);
    } else {
      await _pages.nextPage(duration: d, curve: Motion.emphasized);
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await ref.read(settingsProvider.notifier).change((s) => s.copyWith(onboardingDone: true));
    } catch (_) {
      // Not fatal: onboarding would just show again next launch.
    }
    if (mounted) context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.sm),
              child: Row(
                children: [
                  const Spacer(),
                  AnimatedOpacity(
                    opacity: _isLast ? 0 : 1,
                    duration: Motion.of(context, Motion.fast),
                    child: TextButton(
                      onPressed: _isLast ? null : _finish,
                      child: const Text('Skip', semanticsLabel: 'Skip introduction'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _index = i),
                children: const [
                  _OnboardingPage(
                    hero: AppLogo(size: 112),
                    title: 'Your PDFs, private by design',
                    subtitle: 'PdfReader works entirely on this device.',
                    points: [
                      (Icons.wifi_off_rounded, 'Fully offline — the app has no internet access'),
                      (Icons.block_rounded, 'No ads, no tracking, no analytics'),
                      (Icons.person_off_outlined, 'No account or sign-in, ever'),
                      (Icons.phonelink_lock_rounded, 'Your files never leave your device'),
                    ],
                  ),
                  _OnboardingPage(
                    hero: _IconHero(icon: Icons.auto_stories_rounded),
                    title: 'Made for reading',
                    subtitle: 'Fast, sharp and comfortable, even with huge files.',
                    points: [
                      (Icons.pinch_rounded, 'Smooth scrolling and pinch-to-zoom'),
                      (Icons.contrast_rounded, 'Light, sepia, dark and night page themes'),
                      (Icons.bookmark_border_rounded, 'Picks up right where you left off'),
                      (Icons.manage_search_rounded, 'Search, outline, thumbnails and bookmarks'),
                      (Icons.folder_open_rounded, 'Also opens Word, Excel, CSV, Markdown and text files'),
                    ],
                  ),
                  _OnboardingPage(
                    hero: _IconHero(icon: Icons.edit_note_rounded),
                    title: 'Mark up and organise',
                    subtitle: 'Edit safely — your original is never overwritten unless you say so.',
                    points: [
                      (Icons.border_color_outlined, 'Highlight, draw, add notes and sign'),
                      (Icons.view_carousel_outlined, 'Reorder, rotate, merge and split pages'),
                      (Icons.ios_share_rounded, 'Export to images or text, share a copy'),
                    ],
                  ),
                  _OnboardingPage(
                    hero: _IconHero(icon: Icons.open_in_new_rounded),
                    custom: DefaultAppGuideView(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.md),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PageDots(count: _count, index: _index),
                    const SizedBox(height: Space.md),
                    PrimaryButton(
                      key: Key(_isLast ? 'onboarding.done' : 'onboarding.next'),
                      expand: true,
                      label: _isLast ? 'Get started' : 'Continue',
                      icon: _isLast ? Icons.check_rounded : null,
                      busy: _finishing,
                      onPressed: _next,
                      semanticHint: _isLast ? 'Finish the introduction and open the library' : 'Next page',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.hero,
    this.title,
    this.subtitle,
    this.points = const [],
    this.custom,
  });

  final Widget hero;
  final String? title;
  final String? subtitle;
  final List<(IconData, String)> points;
  final Widget? custom;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final roomy = c.maxHeight > 560;
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Space.lg),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (roomy) ...[
                    Center(child: FadeSlideIn(child: hero)),
                    const SizedBox(height: Space.xl),
                  ],
                  if (title != null)
                    Semantics(
                      header: true,
                      child: Text(title!, textAlign: TextAlign.center, style: t.textTheme.headlineMedium),
                    ),
                  if (subtitle != null) ...[
                    const SizedBox(height: Space.sm),
                    Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyLarge?.copyWith(color: s.onSurfaceVariant),
                    ),
                  ],
                  if (points.isNotEmpty) const SizedBox(height: Space.xl),
                  for (final (i, (icon, text)) in points.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.md),
                      child: Row(
                        children: [
                          IconBadge(icon, color: _pointColors[i % _pointColors.length], size: 42),
                          const SizedBox(width: Space.md),
                          Expanded(child: Text(text, style: t.textTheme.bodyLarge)),
                        ],
                      ),
                    ),
                  ?custom,
                  const SizedBox(height: Space.md),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

const _pointColors = [
  Color(0xFF3B5BDB),
  Color(0xFF7C3AED),
  Color(0xFFDB2777),
  Color(0xFF0D9488),
  Color(0xFFF59E0B),
];

class _IconHero extends StatelessWidget {
  const _IconHero({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(36)),
          gradient: Brand.gradient(s.brightness),
          boxShadow: [BoxShadow(color: Brand.gradientColors[1].withValues(alpha: 0.4), blurRadius: 30, offset: const Offset(0, 12))],
        ),
        child: Stack(alignment: Alignment.center, children: [
          Positioned(
            right: -18,
            top: -18,
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.14)),
            ),
          ),
          Icon(icon, size: 56, color: Colors.white),
        ]),
      ),
    );
  }
}
