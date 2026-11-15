import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/commands/undo_stack.dart';
import 'form_engine.dart';

/// Holds the AcroForm fields of a document and the user's pending edits.
/// Edits are undoable [Command]s; nothing touches the PDF until [buildCopy].
class FormFillController extends ChangeNotifier {
  FormFillController({required this.document, UndoStack? undoStack, FormEngine? engine})
      : undoStack = undoStack ?? UndoStack(),
        _engine = engine ?? FormEngine();

  final PdfDocument document;
  final UndoStack undoStack;
  final FormEngine _engine;

  Uint8List? _bytes;
  List<FormFieldInfo> _fields = const [];
  final Map<String, FormEdit> _edits = {};
  bool _loading = false;
  Object? _error;

  List<FormFieldInfo> get fields => _fields;
  bool get loading => _loading;
  Object? get error => _error;
  bool get hasEdits => _edits.isNotEmpty;
  Map<String, FormEdit> get edits => Map.unmodifiable(_edits);

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _bytes = await document.encodePdf(removeSecurity: true);
      _fields = await _engine.readFields(_bytes!);
    } catch (e) {
      _error = e;
      _fields = const [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Widgets grouped by field name, in document order.
  Map<String, List<FormFieldInfo>> get groups {
    final out = <String, List<FormFieldInfo>>{};
    for (final f in _fields) {
      (out[f.name] ??= []).add(f);
    }
    return out;
  }

  // ---- Effective (edited) values ----------------------------------------

  String textOf(FormFieldInfo f) {
    for (final w in groups[f.name] ?? [f]) {
      final e = _edits[w.key];
      if (e is TextEdit) return e.text;
    }
    return f.value;
  }

  bool isChecked(FormFieldInfo f) {
    if (f.kind == FormFieldKind.radio) {
      for (final w in groups[f.name] ?? [f]) {
        final e = _edits[w.key];
        if (e is CheckEdit && e.checked) return w.key == f.key;
      }
      return f.checked;
    }
    final e = _edits[f.key];
    return e is CheckEdit ? e.checked : f.checked;
  }

  Set<int> selectionOf(FormFieldInfo f) {
    final e = _edits[f.key];
    return e is ChoiceEdit ? e.selected : f.selected;
  }

  // ---- Mutations (undoable) -------------------------------------------------

  Future<void> setText(FormFieldInfo f, String text) {
    final first = (groups[f.name] ?? [f]).first;
    return _set({first.key: text == first.value ? null : TextEdit(first.key, text)}, 'Fill "${f.name}"');
  }

  Future<void> setChecked(FormFieldInfo f, bool checked) {
    if (f.kind == FormFieldKind.radio) {
      final changes = <String, FormEdit?>{
        for (final w in groups[f.name] ?? [f]) w.key: null,
      };
      if (checked && !f.checked) changes[f.key] = CheckEdit(f.key, true);
      return _set(changes, 'Choose "${f.name}"');
    }
    return _set({f.key: checked == f.checked ? null : CheckEdit(f.key, checked)}, 'Toggle "${f.name}"');
  }

  Future<void> setSelection(FormFieldInfo f, Set<int> selected) => _set(
      {f.key: setEquals(selected, f.selected) ? null : ChoiceEdit(f.key, Set.of(selected))}, 'Choose "${f.name}"');

  Future<void> _set(Map<String, FormEdit?> changes, String label) {
    final before = {for (final k in changes.keys) k: _edits[k]};
    void applyMap(Map<String, FormEdit?> m) {
      m.forEach((k, v) => v == null ? _edits.remove(k) : _edits[k] = v);
      notifyListeners();
    }

    return undoStack.run(FnCommand(label, () async => applyMap(changes), () async => applyMap(before)));
  }

  /// Produces a filled copy (fields stay editable unless [flatten]).
  Future<Uint8List> buildCopy({bool flatten = false}) async {
    final bytes = _bytes ?? await document.encodePdf(removeSecurity: true);
    return _engine.apply(bytes, _edits.values.toList(), flatten: flatten);
  }
}
