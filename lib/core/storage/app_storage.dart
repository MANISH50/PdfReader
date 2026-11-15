import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// All app data lives in the app's private sandbox (getApplicationSupportDirectory).
/// Never write to shared/external storage; user-visible output goes through
/// the system share sheet or save dialog only.
class AppDirs {
  AppDirs(this.root);

  final Directory root;

  static Future<AppDirs> resolve() async => AppDirs(await getApplicationSupportDirectory());

  Directory get data => _sub('data');
  Directory get annotations => _sub('annotations');
  Directory get signatures => _sub('signatures');
  Directory get drafts => _sub('drafts');

  /// Imported copies of files received via open-with / share.
  Directory get inbox => _sub('inbox');

  /// Scratch space; wiped on startup and after each export/share.
  Directory get temp => _sub('tmp');

  Directory _sub(String name) {
    final d = Directory(p.join(root.path, name));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }
}

/// Tiny JSON document store with atomic writes (write temp + rename), used
/// for recents, settings, per-document reading state and annotation sidecars.
/// Data sets are small, so this avoids a database dependency.
class JsonStore {
  JsonStore(this.dir);

  final Directory dir;

  File _file(String key) {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(key) || key.contains('..')) {
      throw ArgumentError.value(key, 'key', 'invalid store key');
    }
    return File(p.join(dir.path, '$key.json'));
  }

  Future<Object?> read(String key) async {
    final f = _file(key);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      return null; // corrupted entry: treat as absent rather than crash
    }
  }

  Future<void> write(String key, Object? value) async {
    final f = _file(key);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
  }

  Future<void> delete(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }
}

/// Creates and cleans scratch files. Call [wipe] at startup and after use.
class TempFiles {
  TempFiles(this.dir);

  final Directory dir;
  int _n = 0;

  File create(String extension) => File(
      p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_${_n++}.$extension'));

  Directory createDir() {
    final d = Directory(p.join(dir.path, 'd${DateTime.now().microsecondsSinceEpoch}_${_n++}'));
    d.createSync(recursive: true);
    return d;
  }

  Future<void> wipe() async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      try {
        await e.delete(recursive: true);
      } on FileSystemException {
        // in use; next wipe will get it
      }
    }
  }
}
