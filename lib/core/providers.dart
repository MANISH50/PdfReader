import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/editor/engine/pdfrx_page_editor.dart';
import '../features/editor/save/file_save_service.dart';
import '../features/editor/signature/signature_store.dart';
import '../platform/file_pick_service_impl.dart';
import '../platform/incoming_file_service_impl.dart';
import '../platform/platform_services.dart';
import '../platform/share_service_impl.dart';
import 'export/exporter.dart';
import 'models/app_settings.dart';
import 'pdf/document_service.dart';
import 'pdf/page_editor.dart';
import 'pdf/pdfrx_document_service.dart';
import 'storage/app_storage.dart';
import 'storage/stores.dart';

/// Overridden in main() after resolving the private app directory.
final appDirsProvider = Provider<AppDirs>((ref) => throw UnimplementedError('override in main'));

final jsonStoreProvider = Provider((ref) => JsonStore(ref.watch(appDirsProvider).data));
final tempFilesProvider = Provider((ref) => TempFiles(ref.watch(appDirsProvider).temp));
final recentFilesStoreProvider = Provider((ref) => RecentFilesStore(ref.watch(jsonStoreProvider)));
final readingStateStoreProvider = Provider((ref) => ReadingStateStore(ref.watch(jsonStoreProvider)));
final annotationStoreProvider =
    Provider((ref) => AnnotationStore(JsonStore(ref.watch(appDirsProvider).annotations)));

// ---- Implementations supplied by feature agents (one line each) ----------
// Viewer agent:
final documentServiceProvider = Provider<DocumentService>((ref) => PdfrxDocumentService());
// Editing agent:
final pageEditorProvider = Provider<PageEditor>((ref) =>
    PdfrxPageEditor(loadSignature: SignatureStore(ref.watch(appDirsProvider).signatures).load));
final saveServiceProvider = Provider<SaveService>((ref) => FileSaveService(ref.watch(appDirsProvider)));
// Export agent:
final exportersProvider = Provider<List<Exporter>>((ref) => const []);
// Platform agent:
final incomingFileServiceProvider = Provider<IncomingFileService>((ref) {
  final s = ChannelIncomingFileService(inboxPath: ref.watch(appDirsProvider).inbox.path);
  ref.onDispose(s.dispose);
  return s;
});
final shareServiceProvider = Provider<ShareService>((ref) => SharePlusShareService());
final filePickServiceProvider = Provider<FilePickService>(
    (ref) => PluginFilePickService(inboxPath: ref.watch(appDirsProvider).inbox.path));

// ---- Settings -------------------------------------------------------------
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  static const _key = 'settings';

  @override
  Future<AppSettings> build() async {
    final raw = await ref.read(jsonStoreProvider).read(_key);
    return raw is Map<String, Object?> ? AppSettings.fromJson(raw) : const AppSettings();
  }

  Future<void> change(AppSettings Function(AppSettings) f) async {
    final next = f(state.value ?? const AppSettings());
    state = AsyncData(next);
    await ref.read(jsonStoreProvider).write(_key, next.toJson());
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
