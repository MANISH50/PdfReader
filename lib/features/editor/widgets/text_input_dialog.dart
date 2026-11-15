import 'package:material_ui/material_ui.dart';

/// Multi-line text prompt used for sticky notes and text boxes. Returns null
/// when cancelled. [onDelete] adds a Delete action (returns the empty string
/// sentinel [kDeleteResult]).
const String kDeleteResult = '\u0000delete';

Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String confirmLabel = 'Done',
  bool allowDelete = false,
  int maxLength = 5000,
}) {
  return showDialog<String>(
    context: context,
    builder: (c) => _TextInputDialog(
      title: title,
      initial: initial,
      hint: hint,
      confirmLabel: confirmLabel,
      allowDelete: allowDelete,
      maxLength: maxLength,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.confirmLabel,
    required this.allowDelete,
    required this.maxLength,
  });
  final String title, initial, hint, confirmLabel;
  final bool allowDelete;
  final int maxLength;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 360,
          child: TextField(
            key: const ValueKey('text-input-field'),
            controller: _c,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            maxLength: widget.maxLength,
            decoration: InputDecoration(hintText: widget.hint, border: const OutlineInputBorder()),
          ),
        ),
        actions: [
          if (widget.allowDelete)
            TextButton(
              onPressed: () => Navigator.pop(context, kDeleteResult),
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Delete'),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: Text(widget.confirmLabel)),
        ],
      );
}
