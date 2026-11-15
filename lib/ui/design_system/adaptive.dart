import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Small set of platform-adaptive building blocks: Material on Android,
/// Cupertino-style controls on iOS/macOS where it matters.
bool isCupertino(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
}

Future<bool?> showAdaptiveConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) {
  if (isCupertino(context)) {
    return showCupertinoDialog<bool>(
      context: context,
      builder: (c) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(c, false), child: Text(cancelLabel)),
          CupertinoDialogAction(
            isDestructiveAction: destructive,
            isDefaultAction: !destructive,
            onPressed: () => Navigator.pop(c, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (c) {
      final s = Theme.of(c).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(cancelLabel)),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: s.error, foregroundColor: s.onError)
                : null,
            onPressed: () => Navigator.pop(c, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
}

class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => isCupertino(context)
      ? CupertinoSwitch(value: value, onChanged: onChanged)
      : Switch(value: value, onChanged: onChanged);
}

/// One option of an [AdaptiveSegmented] control.
class Segment<T> {
  const Segment(this.value, this.label, {this.icon, this.key});
  final T value;
  final String label;
  final IconData? icon;

  /// Attached to the segment's label (e.g. for integration tests).
  final Key? key;
}

/// Single-choice segmented control: Material [SegmentedButton] or
/// [CupertinoSlidingSegmentedControl]. Labels shrink (never overflow) at
/// large text scales.
class AdaptiveSegmented<T extends Object> extends StatelessWidget {
  const AdaptiveSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
  });

  final List<Segment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    Widget label(Segment<T> s) => FittedBox(
          key: s.key,
          fit: BoxFit.scaleDown,
          child: Text(s.label, maxLines: 1, softWrap: false),
        );
    final Widget control = isCupertino(context)
        ? SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<T>(
              groupValue: selected,
              onValueChanged: (v) {
                if (v != null) onChanged(v);
              },
              padding: const EdgeInsets.all(Space.xxs),
              children: {
                for (final s in segments)
                  s.value: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: kMinTouchTarget - 8),
                    child: Center(child: label(s)),
                  ),
              },
            ),
          )
        : SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [
                for (final s in segments)
                  ButtonSegment<T>(
                    value: s.value,
                    label: label(s),
                    tooltip: s.label,
                  ),
              ],
              selected: {selected},
              onSelectionChanged: (v) => onChanged(v.first),
            ),
          );
    return Semantics(container: true, label: semanticLabel, child: control);
  }
}

/// Modal bottom sheet with a drag handle, rounded top, safe-area aware and
/// keyboard aware. [builder] content scrolls if it does not fit.
Future<T?> showAppBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  bool expand = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (c) => AppSheet(title: title, expand: expand, child: builder(c)),
  );
}

/// Layout used by [showAppBottomSheet]: optional title, scrollable body.
class AppSheet extends StatelessWidget {
  const AppSheet({super.key, this.title, required this.child, this.expand = false});
  final String? title;
  final Widget child;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxH = mq.size.height * (expand ? 0.92 : 0.85);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH, minHeight: expand ? maxH : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
                child: Semantics(
                  header: true,
                  child: Text(title!, style: Theme.of(context).textTheme.titleLarge),
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: Space.lg),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Platform progress spinner.
class AdaptiveProgress extends StatelessWidget {
  const AdaptiveProgress({super.key, this.size = 20, this.color});
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: isCupertino(context)
            ? CupertinoActivityIndicator(color: color, radius: size / 2)
            : CircularProgressIndicator(strokeWidth: 2.5, color: color),
      );
}

/// Shows a floating snackbar, replacing any visible one.
void showAppSnackBar(BuildContext context, String message, {SnackBarAction? action}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}
