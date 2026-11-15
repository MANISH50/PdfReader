import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/models/document_ref.dart';
import '../../../core/pdf/page_editor.dart';
import '../../../core/providers.dart';
import '../../../ui/design_system/tokens.dart';
import 'form_engine.dart';
import 'form_fill_controller.dart';

/// Lists the document's form fields with simple editors and saves a filled
/// copy. Pops with the saved path (or null).
class FormFillScreen extends ConsumerStatefulWidget {
  const FormFillScreen({super.key, required this.document, required this.pdf, this.controller});
  final DocumentRef document;
  final PdfDocument pdf;

  /// Injected for tests; created from [pdf] otherwise.
  final FormFillController? controller;

  @override
  ConsumerState<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends ConsumerState<FormFillScreen> {
  late final FormFillController _c = widget.controller ?? FormFillController(document: widget.pdf);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) unawaited(_c.load());
  }

  @override
  void dispose() {
    if (widget.controller == null) _c.dispose();
    super.dispose();
  }

  Future<void> _save({required bool flatten}) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _c.buildCopy(flatten: flatten);
      final path = await ref.read(saveServiceProvider).save(bytes,
          mode: SaveMode.saveAsCopy, suggestedName: '${widget.document.baseName} (filled).pdf');
      _c.undoStack.markSaved();
      if (mounted) Navigator.pop(context, path);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not save the filled form')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_c, _c.undoStack]),
      builder: (context, _) {
        final undo = _c.undoStack;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Fill form'),
            actions: [
              IconButton(
                  tooltip: 'Undo',
                  onPressed: undo.canUndo ? () => unawaited(undo.undo()) : null,
                  icon: const Icon(Icons.undo)),
              IconButton(
                  tooltip: 'Redo',
                  onPressed: undo.canRedo ? () => unawaited(undo.redo()) : null,
                  icon: const Icon(Icons.redo)),
              PopupMenuButton<bool>(
                enabled: !_saving && _c.fields.isNotEmpty,
                tooltip: 'Save',
                icon: const Icon(Icons.save_outlined),
                onSelected: (flatten) => unawaited(_save(flatten: flatten)),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: false, child: Text('Save as copy')),
                  PopupMenuItem(value: true, child: Text('Save as copy (flattened, not editable)')),
                ],
              ),
            ],
          ),
          body: _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    if (_c.loading) return const Center(child: CircularProgressIndicator());
    if (_c.error != null) return const Center(child: Text('Could not read the form fields of this PDF.'));
    final groups = _c.groups;
    if (groups.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(Space.lg),
          child: Text('This PDF has no fillable form fields.\n'
              'Use the text box tool to add text anywhere on the page.', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(Space.md),
      children: [
        for (final entry in groups.entries) _fieldTile(context, entry.key, entry.value),
      ],
    );
  }

  Widget _fieldTile(BuildContext context, String name, List<FormFieldInfo> widgets) {
    final f = widgets.first;
    final label = name.isEmpty ? 'Unnamed field' : name;
    final subtitle = 'Page ${f.page}${f.readOnly ? ' · read-only' : ''}';
    switch (f.kind) {
      case FormFieldKind.text:
        return Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: _TextFieldEditor(
            key: ValueKey('form-${f.key}'),
            label: label,
            helper: subtitle,
            value: _c.textOf(f),
            enabled: !f.readOnly,
            multiline: f.multiline,
            onCommit: (v) => unawaited(_c.setText(f, v)),
          ),
        );
      case FormFieldKind.checkbox:
        return CheckboxListTile(
          key: ValueKey('form-${f.key}'),
          title: Text(label),
          subtitle: Text(subtitle),
          value: _c.isChecked(f),
          onChanged: f.readOnly ? null : (v) => unawaited(_c.setChecked(f, v ?? false)),
        );
      case FormFieldKind.radio:
        return Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(title: Text(label), subtitle: Text(subtitle)),
            for (final w in widgets)
              ListTile(
                key: ValueKey('form-${w.key}'),
                leading: Icon(_c.isChecked(w) ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(w.exportValue.isEmpty ? 'Option ${widgets.indexOf(w) + 1}' : w.exportValue),
                onTap: w.readOnly ? null : () => unawaited(_c.setChecked(w, true)),
              ),
          ]),
        );
      case FormFieldKind.combo:
        final sel = _c.selectionOf(f);
        return Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: DropdownButtonFormField<int>(
            key: ValueKey('form-${f.key}'),
            initialValue: sel.isEmpty ? null : sel.first,
            decoration: InputDecoration(labelText: label, helperText: subtitle, border: const OutlineInputBorder()),
            items: [
              for (var i = 0; i < f.options.length; i++) DropdownMenuItem(value: i, child: Text(f.options[i])),
            ],
            onChanged: f.readOnly ? null : (v) => v == null ? null : unawaited(_c.setSelection(f, {v})),
          ),
        );
      case FormFieldKind.list:
        final sel = _c.selectionOf(f);
        return Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(title: Text(label), subtitle: Text(subtitle)),
            for (var i = 0; i < f.options.length; i++)
              CheckboxListTile(
                title: Text(f.options[i]),
                value: sel.contains(i),
                onChanged: f.readOnly
                    ? null
                    : (v) {
                        final next = f.multiSelect ? Set.of(sel) : <int>{};
                        if (v ?? false) {
                          next.add(i);
                        } else {
                          next.remove(i);
                        }
                        unawaited(_c.setSelection(f, next));
                      },
              ),
          ]),
        );
      case FormFieldKind.button:
      case FormFieldKind.signature:
      case FormFieldKind.unknown:
        return ListTile(
          enabled: false,
          title: Text(label),
          subtitle: Text('$subtitle · ${f.kind == FormFieldKind.signature ? 'digital signature field (not supported)' : 'not fillable'}'),
        );
    }
  }
}

class _TextFieldEditor extends StatefulWidget {
  const _TextFieldEditor({
    super.key,
    required this.label,
    required this.helper,
    required this.value,
    required this.enabled,
    required this.multiline,
    required this.onCommit,
  });
  final String label, helper, value;
  final bool enabled, multiline;
  final ValueChanged<String> onCommit;

  @override
  State<_TextFieldEditor> createState() => _TextFieldEditorState();
}

class _TextFieldEditorState extends State<_TextFieldEditor> {
  late final TextEditingController _t = TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_TextFieldEditor old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _t.text) _t.text = widget.value; // undo/redo
  }

  void _commit() {
    if (_t.text != widget.value) widget.onCommit(_t.text);
  }

  @override
  void dispose() {
    _t.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _t,
        focusNode: _focus,
        enabled: widget.enabled,
        minLines: widget.multiline ? 3 : 1,
        maxLines: widget.multiline ? 8 : 1,
        maxLength: 10000,
        buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
        decoration: InputDecoration(
            labelText: widget.label, helperText: widget.helper, border: const OutlineInputBorder()),
        onSubmitted: (_) => _commit(),
      );
}
