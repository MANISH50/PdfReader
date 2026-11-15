import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../core/security/limits.dart';
import 'file_names.dart';
import 'platform_services.dart';

/// Thrown when a picked file exceeds [SecurityLimits.maxFileBytes].
class PickedFileTooLargeException implements Exception {
  const PickedFileTooLargeException(this.displayName);
  final String displayName;
  @override
  String toString() => 'PickedFileTooLargeException($displayName)';
}

/// The subset of file_picker we use, injectable for tests.
abstract interface class FilePickerApi {
  Future<List<PlatformFile>> pickPdfs({required bool multiple});
  Future<Uri?> saveFile({required String fileName, required Uint8List bytes, required String mimeType});
  Future<void> clearTemporaryFiles();
}

class _PluginFilePickerApi implements FilePickerApi {
  const _PluginFilePickerApi();

  @override
  Future<List<PlatformFile>> pickPdfs({required bool multiple}) async {
    if (multiple) {
      return FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
    }
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf']);
    return f == null ? const [] : [f];
  }

  @override
  Future<Uri?> saveFile({required String fileName, required Uint8List bytes, required String mimeType}) =>
      FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mimeType);

  @override
  Future<void> clearTemporaryFiles() => FilePicker.clearTemporaryFiles();
}

/// [FilePickService] backed by file_picker: the system document picker
/// (Android SAF / iOS UIDocumentPicker) — no storage permission needed.
///
/// Picked files are streamed into the private inbox (size-capped, one fresh
/// directory per file named `<sanitised display name>.pdf`), then the picker's own cache copies are cleared, so the rest of the
/// app only sees app-private paths.
class PluginFilePickService implements FilePickService {
  PluginFilePickService({
    required this.inboxPath,
    this.maxBytes = SecurityLimits.maxFileBytes,
    FilePickerApi? api,
  }) : _api = api ?? const _PluginFilePickerApi();

  final String inboxPath;
  final int maxBytes;
  final FilePickerApi _api;
  int _n = 0;

  @override
  Future<List<String>> pickPdfs({bool multiple = false}) async {
    final picked = await _api.pickPdfs(multiple: multiple);
    final out = <String>[];
    try {
      final limit = multiple ? SecurityLimits.maxMergeInputs : 1;
      for (final f in picked.take(limit)) {
        out.add(await _copyIn(f));
      }
    } catch (_) {
      for (final path in out) {
        _deleteQuietly(p.dirname(path));
      }
      rethrow;
    } finally {
      try {
        await _api.clearTemporaryFiles();
      } catch (_) {
        // best effort
      }
    }
    return out;
  }

  Future<String> _copyIn(PlatformFile f) async {
    final name = pdfFileName(f.name);
    final known = f.lengthSync();
    if (known != null && known > maxBytes) throw PickedFileTooLargeException(name);

    // Unique directory per pick; the file inside carries the sanitised
    // display name, so `basename(path)` is what the user expects to see.
    final stamp = '${DateTime.now().microsecondsSinceEpoch}_${_n++}';
    final dir = Directory(p.join(inboxPath, 'pk_$stamp'))..createSync(recursive: true);
    final part = File(p.join(dir.path, '.part'));
    final target = p.join(dir.path, name);
    final sink = part.openWrite();
    var total = 0;
    try {
      await for (final chunk in f.readAsByteStream()) {
        total += chunk.length;
        if (total > maxBytes) throw PickedFileTooLargeException(name);
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close().catchError((Object _) {});
      _deleteQuietly(dir.path);
      rethrow;
    }
    await part.rename(target);
    return target;
  }

  @override
  Future<String?> saveAs(String sourcePath, {required String suggestedName}) async {
    final src = File(sourcePath);
    final length = await src.length();
    if (length > maxBytes) throw PickedFileTooLargeException(suggestedName);
    final name = sanitizeDisplayName(suggestedName);
    final ext = p.extension(name).isEmpty ? p.extension(sourcePath) : '';
    final fileName = '$name$ext';
    final uri = await _api.saveFile(
      fileName: fileName,
      bytes: await src.readAsBytes(),
      mimeType: _mimeFor(fileName),
    );
    if (uri == null) return null;
    // Describe the destination without exposing full provider URIs in the UI.
    return uri.scheme == 'file' ? uri.toFilePath() : fileName;
  }

  static String _mimeFor(String name) => switch (p.extension(name).toLowerCase()) {
        '.pdf' => 'application/pdf',
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.txt' => 'text/plain',
        '.md' => 'text/markdown',
        '.zip' => 'application/zip',
        '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        _ => 'application/octet-stream',
      };

  static void _deleteQuietly(String path) {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        File(path).deleteSync();
      }
    } on FileSystemException {
      // already gone
    }
  }
}
