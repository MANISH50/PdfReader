import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../model/annotation_ops.dart';

/// Saved signatures: transparent PNGs in `AppDirs.signatures`
/// (`<id>.png`). Ids are validated so they can never escape the directory.
class SignatureStore {
  SignatureStore(this.dir);
  final Directory dir;

  static final _idRe = RegExp(r'^[a-z0-9]{4,64}$');
  static bool isValidId(String id) => _idRe.hasMatch(id);

  File fileFor(String id) {
    if (!isValidId(id)) throw ArgumentError.value(id, 'id', 'invalid signature id');
    return File(p.join(dir.path, '$id.png'));
  }

  Future<List<String>> list() async {
    if (!await dir.exists()) return [];
    final out = <(String, DateTime)>[];
    await for (final e in dir.list()) {
      if (e is! File || p.extension(e.path) != '.png') continue;
      final id = p.basenameWithoutExtension(e.path);
      if (isValidId(id)) out.add((id, (await e.stat()).modified));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final e in out) e.$1];
  }

  /// Saves PNG bytes atomically; returns the new signature id.
  Future<String> save(Uint8List png) async {
    final id = newAnnotationId();
    final f = fileFor(id);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(png, flush: true);
    await tmp.rename(f.path);
    return id;
  }

  Future<Uint8List?> load(String id) async {
    if (!isValidId(id)) return null;
    final f = fileFor(id);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> delete(String id) async {
    final f = fileFor(id);
    if (await f.exists()) await f.delete();
  }
}

/// Decoded signature images for the overlay painter. Notifies when an image
/// finishes loading.
class SignatureImageCache extends ChangeNotifier {
  SignatureImageCache(this.store);
  final SignatureStore store;
  final Map<String, ui.Image?> _images = {};
  bool _disposed = false;

  /// Returns the image if loaded, otherwise starts loading and returns null.
  ui.Image? get(String id) {
    if (_images.containsKey(id)) return _images[id];
    _images[id] = null;
    unawaited(_load(id));
    return null;
  }

  Future<void> _load(String id) async {
    try {
      final bytes = await store.load(id);
      if (bytes == null) return;
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: null);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      _images[id] = frame.image;
      notifyListeners();
    } catch (_) {
      // Unreadable signature: draw a placeholder.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final i in _images.values) {
      i?.dispose();
    }
    _images.clear();
    super.dispose();
  }
}
