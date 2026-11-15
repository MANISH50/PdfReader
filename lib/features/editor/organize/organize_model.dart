import 'package:flutter/foundation.dart';

import '../../../core/commands/undo_stack.dart';

/// One page in the organiser: page [pageNumber] of source document
/// [sourceIndex] (0 = the document being organised, 1.. = merged files),
/// turned clockwise by [quarterTurns] relative to its stored rotation.
@immutable
class OrganizeItem {
  const OrganizeItem({required this.id, required this.sourceIndex, required this.pageNumber, this.quarterTurns = 0});
  final int id;
  final int sourceIndex;
  final int pageNumber;
  final int quarterTurns;

  OrganizeItem rotated(int delta) => OrganizeItem(
      id: id, sourceIndex: sourceIndex, pageNumber: pageNumber, quarterTurns: (quarterTurns + delta) & 3);
}

/// Pure page-list model for [OrganizeScreen]; every change is an undoable
/// [Command] on [undoStack]. Selection is UI state and not undone.
class OrganizeModel extends ChangeNotifier {
  OrganizeModel({UndoStack? undoStack}) : undoStack = undoStack ?? UndoStack();

  final UndoStack undoStack;
  List<OrganizeItem> _items = const [];
  final Set<int> _selected = {};
  int _nextId = 0;
  int _baseCount = 0;

  List<OrganizeItem> get items => _items;
  Set<int> get selected => Set.unmodifiable(_selected);
  bool isSelected(int id) => _selected.contains(id);
  List<OrganizeItem> get selectedItems => [for (final i in _items) if (_selected.contains(i.id)) i];

  /// Replaces everything (no undo entry). Used on open / after saving.
  void reset({required int sourceIndex, required int pageCount}) {
    _baseCount = pageCount;
    _items = List.unmodifiable([
      for (var p = 1; p <= pageCount; p++) OrganizeItem(id: _nextId++, sourceIndex: sourceIndex, pageNumber: p),
    ]);
    _selected.clear();
    undoStack.clear();
    notifyListeners();
  }

  void toggleSelected(int id) {
    if (!_selected.remove(id)) _selected.add(id);
    notifyListeners();
  }

  void selectAll() {
    _selected
      ..clear()
      ..addAll(_items.map((e) => e.id));
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  Future<void> _change(String label, List<OrganizeItem> next) {
    final before = _items;
    final after = List<OrganizeItem>.unmodifiable(next);
    void set(List<OrganizeItem> v) {
      _items = v;
      _selected.removeWhere((id) => !_items.any((e) => e.id == id));
      notifyListeners();
    }

    return undoStack.run(FnCommand(label, () async => set(after), () async => set(before)));
  }

  /// Moves the item at [from] so it ends up at index [to].
  Future<void> move(int from, int to) async {
    if (from == to || from < 0 || from >= _items.length) return;
    final next = List.of(_items);
    final it = next.removeAt(from);
    next.insert(to.clamp(0, next.length), it);
    await _change('Move page', next);
  }

  Future<void> rotate(Iterable<int> ids, int quarterTurnsDelta) {
    final set = ids.toSet();
    return _change(quarterTurnsDelta > 0 ? 'Rotate right' : 'Rotate left',
        [for (final i in _items) set.contains(i.id) ? i.rotated(quarterTurnsDelta) : i]);
  }

  /// Deletes [ids]; refuses to delete every page (returns false).
  Future<bool> delete(Iterable<int> ids) async {
    final set = ids.toSet();
    final next = [for (final i in _items) if (!set.contains(i.id)) i];
    if (next.isEmpty || next.length == _items.length) return false;
    await _change(set.length == 1 ? 'Delete page' : 'Delete ${set.length} pages', next);
    return true;
  }

  /// Appends all pages of a newly added source.
  Future<void> append({required int sourceIndex, required int pageCount}) => _change('Add pages', [
        ..._items,
        for (var p = 1; p <= pageCount; p++) OrganizeItem(id: _nextId++, sourceIndex: sourceIndex, pageNumber: p),
      ]);

  /// True when the page list differs from the untouched source document.
  bool get isModified {
    if (_items.length != _baseCount) return true;
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (it.sourceIndex != 0 || it.pageNumber != i + 1 || it.quarterTurns != 0) return true;
    }
    return false;
  }
}
