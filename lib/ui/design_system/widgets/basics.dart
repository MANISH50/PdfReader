import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../adaptive.dart';
import '../tokens.dart';
import 'fancy.dart';

/// Page scaffold with a large collapsing title and sliver body. Content is
/// centred in a readable column on wide windows (see [contentGutter]).
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.actions = const [],
    this.floatingActionButton,
    this.largeTitle = true,
    this.maxContentWidth = kMaxContentWidth,
    this.bottom,
    this.gradientHeader = false,
    this.subtitle,
  });

  /// Show the title in a big brand-gradient header instead of an app bar.
  final bool gradientHeader;

  /// Line under the title in the gradient header.
  final String? subtitle;

  final String title;
  final List<Widget> slivers;
  final List<Widget> actions;
  final Widget? floatingActionButton;
  final bool largeTitle;
  final double maxContentWidth;

  /// Optional widget pinned below the title (e.g. a search field).
  final PreferredSizeWidget? bottom;

  @override
  Widget build(BuildContext context) {
    final gutter = contentGutter(context, maxWidth: maxContentWidth);
    final titleWidget = Text(title, maxLines: 1, overflow: TextOverflow.ellipsis);
    final Widget appBar;
    if (gradientHeader) {
      final t = Theme.of(context);
      final canPop = ModalRoute.of(context)?.canPop ?? false;
      appBar = SliverToBoxAdapter(
        child: GradientHeader(
          bottomPadding: Space.lg,
          child: Padding(
            padding: EdgeInsets.fromLTRB(canPop ? Space.xs : gutter, Space.xs, Space.sm, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (canPop) const BackButton(color: Colors.white),
                const Spacer(),
                ...actions,
              ]),
              Padding(
                padding: EdgeInsets.only(left: canPop ? gutter - Space.xs : 0, top: Space.sm),
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: t.textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: EdgeInsets.only(left: canPop ? gutter - Space.xs : 0, top: Space.xxs),
                  child: Text(subtitle!, style: t.textTheme.bodyMedium?.copyWith(color: Colors.white)),
                ),
            ]),
          ),
        ),
      );
    } else {
      appBar = largeTitle
        ? SliverAppBar.large(title: titleWidget, actions: actions, bottom: bottom)
        : SliverAppBar(pinned: true, title: titleWidget, actions: actions, bottom: bottom);
    }
    return Scaffold(
      floatingActionButton: floatingActionButton,
      body: CustomScrollView(
        slivers: [
          appBar,
          for (final s in slivers)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              sliver: s,
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: Space.xxl + Space.xxl)),
        ],
      ),
    );
  }
}

/// Section title used in lists and settings.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding});
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(Space.xs, Space.lg, Space.xs, Space.sm),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary, letterSpacing: 0.3),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Friendly placeholder for empty lists: icon badge, title, body, action.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action, this.illustration});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  /// Replaces the default icon badge.
  final Widget? illustration;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              illustration ??
                  ExcludeSemantics(
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [s.primaryContainer, s.secondaryContainer],
                        ),
                      ),
                      child: Icon(icon, size: 44, color: s.onPrimaryContainer),
                    ),
                  ),
              const SizedBox(height: Space.lg),
              Semantics(
                header: true,
                child: Text(title, textAlign: TextAlign.center, style: t.textTheme.titleLarge),
              ),
              if (message != null) ...[
                const SizedBox(height: Space.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                ),
              ],
              if (action != null) ...[const SizedBox(height: Space.lg), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Main call-to-action button: filled, 52dp tall, optional icon and busy
/// state. Cupertino-flavoured on Apple platforms.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.expand = false,
    this.semanticHint,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;
  final String? semanticHint;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final enabled = onPressed != null && !busy;
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy) AdaptiveProgress(size: 18, color: s.onPrimary) else if (icon != null) Icon(icon, size: 20),
        if (busy || icon != null) const SizedBox(width: Space.sm),
        Flexible(child: Text(label, textAlign: TextAlign.center)),
      ],
    );
    final Widget button = isCupertino(context)
        ? CupertinoButton.filled(
            minimumSize: const Size(kMinTouchTarget, 52),
            borderRadius: Radii.card,
            padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
            onPressed: enabled ? onPressed : null,
            child: DefaultTextStyle.merge(
              style: TextStyle(color: s.onPrimary, fontWeight: FontWeight.w600),
              child: IconTheme.merge(
                data: IconThemeData(color: s.onPrimary),
                child: content,
              ),
            ),
          )
        : AnimatedOpacity(
            opacity: enabled || busy ? 1 : 0.5,
            duration: Motion.of(context, Motion.fast),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: Radii.card,
                gradient: Brand.gradient(s.brightness, begin: Alignment.centerLeft, end: Alignment.centerRight),
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: Brand.gradientColors[1].withValues(alpha: 0.30),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  disabledBackgroundColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white,
                  shadowColor: Colors.transparent,
                ),
                onPressed: enabled ? onPressed : null,
                child: content,
              ),
            ),
          );
    return Semantics(
      button: true,
      enabled: enabled,
      hint: semanticHint,
      excludeSemantics: false,
      child: expand ? SizedBox(width: double.infinity, child: button) : button,
    );
  }
}

/// Animated page indicator dots (active dot stretches into a pill).
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final d = Motion.of(context, Motion.normal);
    return Semantics(
      label: 'Page ${index + 1} of $count',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < count; i++)
              AnimatedContainer(
                duration: d,
                curve: Motion.standard,
                margin: const EdgeInsets.symmetric(horizontal: Space.xs),
                width: i == index ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i == index ? null : s.outlineVariant,
                  gradient: i == index
                      ? Brand.gradient(s.brightness, begin: Alignment.centerLeft, end: Alignment.centerRight)
                      : null,
                  borderRadius: Radii.pill,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Sliver that fills the rest of the viewport and centres [child], but grows
/// (and scrolls) when the child is taller — safe at large text scales and
/// in landscape, unlike `SliverFillRemaining(hasScrollBody: false)` with
/// children whose intrinsic height is unreliable.
class SliverFillOrFit extends StatelessWidget {
  const SliverFillOrFit({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, c) {
      final rest = c.viewportMainAxisExtent - c.precedingScrollExtent;
      return SliverToBoxAdapter(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: rest > 0 ? rest : 0),
          child: Center(child: child),
        ),
      );
    },
  );
}
