import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

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
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(cancelLabel)),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(confirmLabel)),
      ],
    ),
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
