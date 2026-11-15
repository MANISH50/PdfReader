import 'package:flutter/foundation.dart';

/// A reversible edit. Every editing operation (annotation add/remove/move,
/// page rotate/delete/reorder, form value change) must be a [Command] executed
/// through an [UndoStack] so undo/redo works uniformly.
abstract class Command {
  String get label;
  Future<void> execute();
  Future<void> undo();
}

/// Simple command composed of two closures.
class FnCommand implements Command {
  FnCommand(this.label, this._do, this._undo);
  @override
  final String label;
  final Future<void> Function() _do;
  final Future<void> Function() _undo;
  @override
  Future<void> execute() => _do();
  @override
  Future<void> undo() => _undo();
}

class UndoStack extends ChangeNotifier {
  UndoStack({this.limit = 200});

  final int limit;
  final List<Command> _undo = [];
  final List<Command> _redo = [];
  bool _busy = false;

  bool get canUndo => _undo.isNotEmpty && !_busy;
  bool get canRedo => _redo.isNotEmpty && !_busy;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// True when there are changes since the last [markSaved].
  bool get isDirty => _top != _savedTop;
  Command? get _top => _undo.isEmpty ? null : _undo.last;
  Command? _savedTop;

  Future<void> run(Command c) => _guard(() async {
        await c.execute();
        _undo.add(c);
        if (_undo.length > limit) _undo.removeAt(0);
        _redo.clear();
      });

  Future<void> undo() => _guard(() async {
        if (_undo.isEmpty) return;
        final c = _undo.removeLast();
        await c.undo();
        _redo.add(c);
      });

  Future<void> redo() => _guard(() async {
        if (_redo.isEmpty) return;
        final c = _redo.removeLast();
        await c.execute();
        _undo.add(c);
      });

  void markSaved() {
    _savedTop = _top;
    notifyListeners();
  }

  void clear() {
    _undo.clear();
    _redo.clear();
    _savedTop = null;
    notifyListeners();
  }

  Future<void> _guard(Future<void> Function() f) async {
    if (_busy) return;
    _busy = true;
    try {
      await f();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
