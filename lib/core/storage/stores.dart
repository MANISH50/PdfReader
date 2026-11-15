import '../models/annotation.dart';
import '../models/document_ref.dart';
import '../models/reading_state.dart';
import 'app_storage.dart';

class RecentFilesStore {
  RecentFilesStore(this._store, {this.max = 100});
  final JsonStore _store;
  final int max;
  static const _key = 'recents';

  Future<List<DocumentRef>> load() async {
    final raw = await _store.read(_key);
    if (raw is! List) return [];
    return [
      for (final e in raw)
        if (e is Map<String, Object?>) DocumentRef.fromJson(e)
    ];
  }

  Future<void> touch(DocumentRef ref) async {
    final list = await load()
      ..removeWhere((r) => r.id == ref.id)
      ..insert(0, ref);
    await _store.write(_key, [for (final r in list.take(max)) r.toJson()]);
  }

  Future<void> remove(String id) async {
    final list = await load()..removeWhere((r) => r.id == id);
    await _store.write(_key, [for (final r in list) r.toJson()]);
  }

  Future<void> clear() => _store.delete(_key);
}

class ReadingStateStore {
  ReadingStateStore(this._store);
  final JsonStore _store;

  Future<ReadingState> load(String docId) async {
    final raw = await _store.read('state_$docId');
    return raw is Map<String, Object?> ? ReadingState.fromJson(raw) : const ReadingState();
  }

  Future<void> save(String docId, ReadingState s) => _store.write('state_$docId', s.toJson());
}

class AnnotationStore {
  AnnotationStore(this._store);
  final JsonStore _store;

  Future<List<Annotation>> load(String docId) async {
    final raw = await _store.read('annot_$docId');
    if (raw is! List) return [];
    final out = <Annotation>[];
    for (final e in raw) {
      try {
        out.add(Annotation.fromJson(e as Map<String, Object?>));
      } catch (_) {
        // skip corrupt entry
      }
    }
    return out;
  }

  Future<void> save(String docId, List<Annotation> list) =>
      _store.write('annot_$docId', [for (final a in list) a.toJson()]);
}
