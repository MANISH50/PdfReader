import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// Big gradient header with a curved bottom edge and soft decorative
/// circles. [child] sits on the gradient in white.
class GradientHeader extends StatelessWidget {
  const GradientHeader({super.key, required this.child, this.bottomPadding = Space.xl});
  final Widget child;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(Radii.xl + 4)),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: Brand.gradient(s.brightness)),
        child: Stack(
          children: [
            Positioned(right: -60, top: -40, child: _Circle(size: 200, alpha: 0.10)),
            Positioned(left: -30, bottom: -70, child: _Circle(size: 160, alpha: 0.08)),
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top, bottom: bottomPadding),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white),
                child: IconTheme.merge(
                  data: const IconThemeData(color: Colors.white),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.size, required this.alpha});
  final double size, alpha;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: alpha),
      ),
    ),
  );
}

/// Rounded square in [color] holding a white [icon] (settings rows, quick
/// actions, file types).
class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, required this.color, this.size = 36});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.18)!, color],
        ),
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.56),
    ),
  );
}

/// Circular quick-action button with a label underneath.
class QuickAction extends StatelessWidget {
  const QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final enabled = onTap != null;
    final button = Semantics(
      button: true,
      enabled: enabled,
      label: tooltip ?? label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.card,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm, horizontal: Space.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedOpacity(
                opacity: enabled ? 1 : 0.45,
                duration: Motion.of(context, Motion.fast),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color.lerp(color, Colors.white, 0.2)!, color],
                    ),
                    boxShadow: [
                      BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 5)),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white, size: 26),
                ),
              ),
              const SizedBox(height: Space.xs + 2),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelMedium),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// Floating, rounded, frosted-glass bar. Used for the viewer and reader
/// toolbars so content shows softly through.
class GlassBar extends StatelessWidget {
  const GlassBar({super.key, required this.child, required this.color, this.borderColor, this.radius = Radii.lg});
  final Widget child;
  final Color color;
  final Color? borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.82),
              borderRadius: r,
              border: Border.all(color: (borderColor ?? Colors.white).withValues(alpha: 0.18), width: 0.8),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Extended FAB painted with the brand gradient.
class GradientFab extends StatelessWidget {
  const GradientFab({super.key, required this.label, required this.icon, this.onPressed, this.tooltip});
  final Widget label;
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final fab = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: Radii.pill,
        gradient: Brand.gradient(s.brightness, begin: Alignment.centerLeft, end: Alignment.centerRight),
        boxShadow: [
          BoxShadow(color: Brand.gradientColors[1].withValues(alpha: 0.4), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56, minWidth: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.lg - 4),
              child: IconTheme.merge(
                data: const IconThemeData(color: Colors.white),
                child: DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.labelLarge!.copyWith(color: Colors.white, fontSize: 16),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      icon,
                      const SizedBox(width: Space.sm),
                      Flexible(child: label),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: tooltip == null ? fab : Tooltip(message: tooltip, child: fab),
    );
  }
}
