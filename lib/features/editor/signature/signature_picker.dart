import 'package:material_ui/material_ui.dart';

import '../../../ui/design_system/tokens.dart';
import 'signature_pad_screen.dart';
import 'signature_store.dart';

/// Bottom sheet listing saved signatures with "New signature". Returns the
/// chosen signature id, or null.
Future<String?> pickSignature(BuildContext context, SignatureStore store) async {
  final ids = await store.list();
  if (!context.mounted) return null;
  if (ids.isEmpty) return SignaturePadScreen.open(context, store);
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => _SignatureSheet(store: store, initial: ids),
  );
}

class _SignatureSheet extends StatefulWidget {
  const _SignatureSheet({required this.store, required this.initial});
  final SignatureStore store;
  final List<String> initial;
  @override
  State<_SignatureSheet> createState() => _SignatureSheetState();
}

class _SignatureSheetState extends State<_SignatureSheet> {
  late List<String> _ids = widget.initial;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Signatures', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Space.sm),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final id in _ids)
                      ListTile(
                        title: SizedBox(
                          height: 56,
                          child: Image.file(widget.store.fileFor(id),
                              fit: BoxFit.contain,
                              alignment: Alignment.centerLeft,
                              errorBuilder: (_, _, _) => const Text('Unreadable signature')),
                        ),
                        onTap: () => Navigator.pop(context, id),
                        trailing: IconButton(
                          tooltip: 'Delete signature',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await widget.store.delete(id);
                            final next = await widget.store.list();
                            if (mounted) setState(() => _ids = next);
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Space.sm),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('New signature'),
                onPressed: () async {
                  final nav = Navigator.of(context);
                  final id = await SignaturePadScreen.open(context, widget.store);
                  if (id != null) nav.pop(id);
                },
              ),
              const SizedBox(height: Space.md),
            ],
          ),
        ),
      );
}

/// Convenience used by the editor session.
Future<void> chooseSignatureInto(
    BuildContext context, SignatureStore store, void Function(String id) onChosen) async {
  final id = await pickSignature(context, store);
  if (id != null) onChosen(id);
}
