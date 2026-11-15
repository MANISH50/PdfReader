import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// Entrance animation: fades in while sliding up a little. Plays once on
/// first build after [delay]. Shows the child immediately when the OS asks
/// for reduced motion.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = Motion.slow,
    this.offset = const Offset(0, 0.06),
  });

  /// Staggered entrance for item [index] of a list (delay is capped).
  FadeSlideIn.staggered({Key? key, required int index, required Widget child})
      : this(
          key: key,
          delay: Motion.stagger * (index.clamp(0, 10)),
          child: child,
        );

  final Widget child;
  final Duration delay;
  final Duration duration;

  /// Start offset as a fraction of the child's size.
  final Offset offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final Duration _total = widget.delay + widget.duration;
  late final AnimationController _c = AnimationController(vsync: this, duration: _total);
  late final Animation<double> _curve = CurvedAnimation(
    parent: _c,
    curve: Interval(
      _total.inMicroseconds == 0 ? 0 : widget.delay.inMicroseconds / _total.inMicroseconds,
      1,
      curve: Motion.standard,
    ),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: Tween(begin: widget.offset, end: Offset.zero).animate(_curve),
          child: widget.child,
        ),
      );
}
