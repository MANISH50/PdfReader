import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/pdf/page_editor.dart';
import '../../../core/storage/app_storage.dart';

class SaveException implements Exception {
  const SaveException(this.message);
  final String message;
  @override
  String toString() => 'SaveException: $message';
}

/// [SaveService] writing into app-private storage.
///
/// * [SaveMode.saveAsCopy] (default): writes `<name> (edited).pdf` (unique
///   name) into `<appSupport>/documents/` and returns its path. Use the
///   platform `FilePickService.saveAs` to export it elsewhere.
/// * [SaveMode.overwriteOriginal]: only when [originalPath] resolves inside
///   the app's private root and is writable; then atomic temp + fsync +
///   rename in the same directory. Otherwise it falls back to a copy — check
///   whether the returned path equals [originalPath] to know which happened.
///   The UI must have confirmed the overwrite before calling.
class FileSaveService implements SaveService {
  FileSaveService(this.dirs);
  final AppDirs dirs;

  Directory get outputDir {
    final d = Directory(p.join(dirs.root.path, 'documents'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  @override
  Future<String> save(List<int> bytes,
      {required SaveMode mode, required String suggestedName, String? originalPath}) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (!_looksLikePdf(data)) throw const SaveException('Output is not a PDF');
    if (mode == SaveMode.overwriteOriginal && originalPath != null && await canOverwrite(originalPath)) {
      await _atomicWrite(File(originalPath), data);
      return originalPath;
    }
    final target = await uniqueFile(outputDir, copyName(suggestedName));
    await _atomicWrite(target, data);
    return target.path;
  }

  /// True if [path] is an existing, writable file inside the app's private
  /// root (symlinks resolved).
  Future<bool> canOverwrite(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      final real = await f.resolveSymbolicLinks();
      final root = await dirs.root.resolveSymbolicLinks();
      if (!p.isWithin(root, real)) return false;
      final raf = await f.open(mode: FileMode.append);
      await raf.close();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static bool _looksLikePdf(Uint8List b) {
    if (b.length < 8) return false;
    final head = String.fromCharCodes(b.sublist(0, b.length < 1024 ? b.length : 1024));
    return head.contains('%PDF-');
  }

  static Future<void> _atomicWrite(File target, Uint8List data) async {
    final tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      final raf = await tmp.open(mode: FileMode.write);
      try {
        await raf.writeFrom(data);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await tmp.rename(target.path);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      throw SaveException('Could not write file: ${e.runtimeType}');
    }
  }

  /// "Report.pdf" → "Report (edited).pdf"; strips path separators and
  /// control characters; never empty.
  static String copyName(String suggested, {String suffix = ' (edited)'}) {
    var base = p.basenameWithoutExtension(sanitize(suggested));
    if (base.isEmpty) base = 'Document';
    if (!base.endsWith(suffix.trim()) && !base.endsWith(suffix)) base = '$base$suffix';
    return '$base.pdf';
  }

  static String sanitize(String name) {
    var s = name.split(RegExp(r'[/\\]')).last;
    s = s.replaceAll(RegExp(r'[\x00-\x1F\x7F:*?"<>|]'), '_').trim();
    s = s.replaceAll(RegExp(r'^\.+'), '');
    if (s.length > 120) {
      final ext = p.extension(s);
      s = s.substring(0, 120 - ext.length) + ext;
    }
    return s;
  }

  /// [name] in [dir], or "name (2).pdf", "name (3).pdf", ... if taken.
  static Future<File> uniqueFile(Directory dir, String name) async {
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name).isEmpty ? '.pdf' : p.extension(name);
    var f = File(p.join(dir.path, '$base$ext'));
    var n = 2;
    while (await f.exists()) {
      f = File(p.join(dir.path, '$base ($n)$ext'));
      n++;
    }
    return f;
  }
}
