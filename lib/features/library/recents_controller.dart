import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/document_ref.dart';
import '../../core/models/reading_state.dart';
import '../../core/providers.dart';
import '../../ui/design_system/widgets/document_tile.dart';

/// A recent file together with its per-document reading state.
class RecentEntry {
  const RecentEntry(this.doc, this.state);
  final DocumentRef doc;
  final ReadingState state;

  DocumentTileData get tileData => DocumentTileData(
        id: doc.id,
        name: doc.displayName,
        sizeBytes: doc.sizeBytes,
        lastOpened: state.lastOpened,
        // Only show a page label once the user has moved past page 1.
        page: state.pageNumber > 1 ? state.pageNumber : null,
      );
}

/// Whether a file still exists. Overridable in tests.
final fileExistsProvider = Provider<bool Function(String path)>((ref) => (p) => File(p).existsSync());

/// Recent documents, newest first. Entries whose file disappeared are pruned
/// from the store when loaded.
class RecentsNotifier extends AsyncNotifier<List<RecentEntry>> {
  @override
  Future<List<RecentEntry>> build() async {
    final store = ref.watch(recentFilesStoreProvider);
    final states = ref.watch(readingStateStoreProvider);
    final exists = ref.watch(fileExistsProvider);
    final docs = await store.load();
    final out = <RecentEntry>[];
    for (final d in docs) {
      if (!exists(d.path)) {
        await store.remove(d.id);
        continue;
      }
      ReadingState s;
      try {
        s = await states.load(d.id);
      } catch (_) {
        s = const ReadingState();
      }
      out.add(RecentEntry(d, s));
    }
    return out;
  }

  /// Removes an entry from recents (the file itself is untouched).
  Future<void> remove(String id) async {
    final current = state.value;
    if (current != null) state = AsyncData([for (final e in current) if (e.doc.id != id) e]);
    await ref.read(recentFilesStoreProvider).remove(id);
  }

  /// Puts an entry back (undo of [remove]).
  Future<void> restore(RecentEntry entry, int index) async {
    final current = [...?state.value];
    current.insert(index.clamp(0, current.length), entry);
    state = AsyncData(current);
    // The store only supports "move to front"; rewrite in the visible order.
    final store = ref.read(recentFilesStoreProvider);
    for (final e in current.reversed) {
      await store.touch(e.doc);
    }
  }

  /// Records [doc] as just opened.
  Future<void> touch(DocumentRef doc) async {
    await ref.read(recentFilesStoreProvider).touch(doc);
    ref.invalidateSelf();
  }

  Future<void> clearAll() async {
    state = const AsyncData([]);
    await ref.read(recentFilesStoreProvider).clear();
  }
}

final recentsProvider = AsyncNotifierProvider<RecentsNotifier, List<RecentEntry>>(RecentsNotifier.new);

/// Case-insensitive filter by file name.
List<RecentEntry> filterRecents(List<RecentEntry> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return [for (final e in all) if (e.doc.displayName.toLowerCase().contains(q)) e];
}
