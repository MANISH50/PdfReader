import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show Color, Offset, Rect;

import '../../core/commands/undo_stack.dart';
import '../../core/models/annotation.dart';
import '../../core/storage/stores.dart';
import 'model/annotation_ops.dart';

/// Owns the annotations of one document.
///
/// * Loads from / persists to the app-private [AnnotationStore] sidecar.
/// * Every mutation is a [Command] run through [undoStack].
/// * Every change is autosaved to the sidecar after [autosaveDelay]
///   (debounced), so a crash loses at most that window. Call [flush] to
///   persist immediately (done automatically on [dispose]).
class AnnotationController extends ChangeNotifier {
  AnnotationController({
    required this.docId,
    required AnnotationStore store,
    UndoStack? undoStack,
    this.autosaveDelay = const Duration(milliseconds: 800),
  })  : _store = store, // ignore: prefer_initializing_formals
        undoStack = undoStack ?? UndoStack();

  final String docId;
  final AnnotationStore _store;
  final UndoStack undoStack;
  final Duration autosaveDelay;

  final List<Annotation> _items = [];
  Timer? _debounce;
  bool _loaded = false;
  bool _disposed = false;
  String? _selectedId;
  Future<void>? _pendingWrite;

  bool get isLoaded => _loaded;
  List<Annotation> get annotations => List.unmodifiable(_items);
  List<Annotation> forPage(int page) => [for (final a in _items) if (a.page == page) a];
  Annotation? byId(String id) {
    for (final a in _items) {
      if (a.id == id) return a;
    }
    return null;
  }

  String? get selectedId => _selectedId;
  Annotation? get selected => _selectedId == null ? null : byId(_selectedId!);

  /// True when a debounced write is still pending.
  bool get hasPendingSave => _debounce?.isActive ?? false;

  Future<void> load() async {
    final list = await _store.load(docId);
    _items
      ..clear()
      ..addAll(list);
    _loaded = true;
    _notify();
  }

  void select(String? id) {
    if (_selectedId == id) return;
    _selectedId = id;
    _notify();
  }

  // ---- Public mutations (all undoable) ------------------------------------

  Future<void> add(Annotation a) => undoStack.run(AddAnnotationCommand(this, a));

  Future<void> remove(String id) async {
    final a = byId(id);
    if (a != null) await undoStack.run(RemoveAnnotationCommand(this, a));
  }

  Future<void> removeSelected() async {
    final id = _selectedId;
    if (id != null) await remove(id);
  }

  /// Replaces the annotation with the same id as [next].
  Future<void> update(Annotation next, {String label = 'Edit annotation'}) async {
    final prev = byId(next.id);
    if (prev == null) return;
    await undoStack.run(UpdateAnnotationCommand(this, prev, next, label: label));
  }

  Future<void> move(String id, Offset delta) async {
    final a = byId(id);
    if (a == null || delta == Offset.zero) return;
    await update(translateAnnotation(a, delta), label: 'Move annotation');
  }

  Future<void> resize(String id, Rect to) async {
    final a = byId(id);
    if (a == null) return;
    await update(resizeAnnotation(a, _resizeFrame(a), to), label: 'Resize annotation');
  }

  Future<void> recolor(String id, Color c) async {
    final a = byId(id);
    if (a != null) await update(recolorAnnotation(a, c), label: 'Change color');
  }

  Future<void> editText(String id, String text) async {
    final a = byId(id);
    if (a != null) await update(withText(a, text), label: 'Edit text');
  }

  /// Adds a highlight / underline / strike-out from a text selection.
  /// [rects] are PDF-space rects (any edge order, see annotation_ops.dart).
  Future<void> addTextMarkup({
    required int page,
    required MarkupKind kind,
    required List<Rect> rects,
    required Color color,
    String? text,
  }) async {
    if (rects.isEmpty) return;
    await add(TextMarkupAnnotation(
      id: newAnnotationId(),
      page: page,
      color: color,
      createdAt: DateTime.now(),
      kind: kind,
      rects: [for (final r in rects) normalizeRect(r)],
      text: text,
    ));
  }

  /// Bounds frame used for resizing (without stroke inflation).
  static Rect _resizeFrame(Annotation a) => switch (a) {
        ShapeAnnotation(:final bounds) => normalizeRect(bounds),
        InkAnnotation(:final strokeWidth) => annotationBounds(a).deflate(strokeWidth / 2),
        _ => annotationBounds(a),
      };

  static Rect resizeFrameOf(Annotation a) => _resizeFrame(a);

  // ---- Raw operations used by commands -------------------------------------

  void insertRaw(Annotation a, [int? index]) {
    _items.removeWhere((e) => e.id == a.id);
    if (index == null || index < 0 || index > _items.length) {
      _items.add(a);
    } else {
      _items.insert(index, a);
    }
    _changed();
  }

  /// Removes by id; returns the former index or -1.
  int removeRaw(String id) {
    final i = _items.indexWhere((e) => e.id == id);
    if (i >= 0) {
      _items.removeAt(i);
      if (_selectedId == id) _selectedId = null;
      _changed();
    }
    return i;
  }

  void replaceRaw(Annotation a) {
    final i = _items.indexWhere((e) => e.id == a.id);
    if (i >= 0) {
      _items[i] = a;
      _changed();
    }
  }

  void _changed() {
    _scheduleSave();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(autosaveDelay, () => unawaited(flush()));
  }

  /// Persists the current annotations now.
  Future<void> flush() async {
    _debounce?.cancel();
    _debounce = null;
    final prev = _pendingWrite;
    if (prev != null) await prev;
    final snapshot = List<Annotation>.of(_items);
    final w = _store.save(docId, snapshot);
    _pendingWrite = w;
    try {
      await w;
    } finally {
      if (identical(_pendingWrite, w)) _pendingWrite = null;
    }
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) unawaited(flush());
    _debounce?.cancel();
    _disposed = true;
    super.dispose();
  }
}

class AddAnnotationCommand implements Command {
  AddAnnotationCommand(this.controller, this.annotation);
  final AnnotationController controller;
  final Annotation annotation;
  int? _index;
  @override
  String get label => 'Add ${annotation.type}';
  @override
  Future<void> execute() async => controller.insertRaw(annotation, _index);
  @override
  Future<void> undo() async => _index = controller.removeRaw(annotation.id);
}

class RemoveAnnotationCommand implements Command {
  RemoveAnnotationCommand(this.controller, this.annotation);
  final AnnotationController controller;
  final Annotation annotation;
  int _index = -1;
  @override
  String get label => 'Delete ${annotation.type}';
  @override
  Future<void> execute() async => _index = controller.removeRaw(annotation.id);
  @override
  Future<void> undo() async => controller.insertRaw(annotation, _index);
}

class UpdateAnnotationCommand implements Command {
  UpdateAnnotationCommand(this.controller, this.before, this.after, {this.label = 'Edit annotation'})
      : assert(before.id == after.id);
  final AnnotationController controller;
  final Annotation before;
  final Annotation after;
  @override
  final String label;
  @override
  Future<void> execute() async => controller.replaceRaw(after);
  @override
  Future<void> undo() async => controller.replaceRaw(before);
}
