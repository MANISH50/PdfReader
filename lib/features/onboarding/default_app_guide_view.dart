import 'package:material_ui/material_ui.dart';

import '../../ui/design_system/design_system.dart';
import 'default_app_steps.dart';

/// Numbered steps for making PdfReader the PDF app on this platform.
/// Used on the last onboarding page and from Settings.
class DefaultAppGuideView extends StatelessWidget {
  const DefaultAppGuideView({super.key, this.showTitle = true, this.guide});

  final bool showTitle;

  /// Defaults to the guide for the current platform.
  final DefaultAppGuide? guide;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final g = guide ?? defaultAppGuideFor(t.platform);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle) ...[
          Semantics(header: true, child: Text(g.title, style: t.textTheme.headlineSmall)),
          const SizedBox(height: Space.sm),
        ],
        Text(g.intro, style: t.textTheme.bodyLarge?.copyWith(color: s.onSurfaceVariant)),
        const SizedBox(height: Space.lg),
        for (var i = 0; i < g.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: s.primaryContainer, shape: BoxShape.circle),
                    child: Text(
                      '${i + 1}',
                      semanticsLabel: 'Step ${i + 1}.',
                      textScaler: TextScaler.noScaling,
                      style: t.textTheme.titleSmall?.copyWith(color: s.onPrimaryContainer),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: Space.xs),
                      child: Text(g.steps[i], style: t.textTheme.bodyLarge),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (g.tip != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Text(g.tip!, style: t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
          ),
        if (g.note != null)
          Container(
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(color: s.secondaryContainer, borderRadius: Radii.card),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: s.onSecondaryContainer, size: 20),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    g.note!,
                    style: t.textTheme.bodyMedium?.copyWith(color: s.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Shows the guide in a bottom sheet (reachable from Settings).
Future<void> showDefaultAppGuideSheet(BuildContext context) => showAppBottomSheet<void>(
      context,
      builder: (_) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: Space.lg),
        child: DefaultAppGuideView(),
      ),
    );
