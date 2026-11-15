import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when a name or path would escape the directory it must stay in.
class UnsafePathException implements Exception {
  const UnsafePathException(this.message);
  final String message;
  @override
  String toString() => 'UnsafePathException: $message';
}

/// Sanitizes file names that come from other apps (share/open-with display
/// names, PDF titles, user input) before they are shown or used on disk.
///
/// The result never contains path separators, control/format characters,
/// bidi overrides (e.g. U+202E, which can make `exe.pdf` look like `fdp.exe`),
/// zero-width characters or Windows-reserved characters; it is never `.`/`..`,
/// never a Windows device name (CON, NUL, COM1...), never starts with `.` or
/// `-`, and is at most [maxUtf8Bytes] UTF-8 bytes long.
abstract final class SafeFilename {
  /// Below the common 255-byte file-system limit, leaving room for suffixes
  /// such as " (12)" and temp extensions.
  static const int maxUtf8Bytes = 200;

  static const String defaultFallback = 'document';

  // C0/C1 controls and DEL.
  static final _controls = RegExp('[\u0000-\u001F\u007F-\u009F]');

  // Bidi controls, zero-width / invisible format characters, BOM, soft hyphen,
  // interlinear annotation, tag characters handled separately (astral).
  static final _invisible = RegExp(
    '[\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180F\u200B-\u200F'
    '\u202A-\u202E\u2060-\u206F\u3164\uFE00-\uFE0F\uFEFF\uFFA0\uFFF0-\uFFFB]',
  );

  // Unicode space separators other than U+0020.
  static final _spaces = RegExp('[\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\\s]+');

  // Separators and characters invalid on Windows/FAT, plus look-alike slashes
  // (U+2044 fraction slash, U+2215 division slash, U+FF0F/U+FF3C full-width).
  static final _reserved = RegExp('[/\\\\<>:"|?*\u2044\u2215\u29F8\uFF0F\uFF3C]');

  static final _windowsDevice = RegExp(
    r'^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[0-9\u00B9\u00B2\u00B3]|lpt[0-9\u00B9\u00B2\u00B3])$',
    caseSensitive: false,
  );

  /// Returns a safe single-component file name.
  ///
  /// [forceExtension] (e.g. `pdf`, without dot) is appended unless the name
  /// already ends with it (case-insensitive), so `invoice.exe` becomes
  /// `invoice.exe.pdf`.
  static String sanitize(
    String? raw, {
    String fallback = defaultFallback,
    String? forceExtension,
    int maxBytes = maxUtf8Bytes,
  }) {
    var s = raw ?? '';
    // Avoid quadratic work on absurd inputs; anything beyond this is cut anyway.
    if (s.length > 4096) s = s.substring(0, 4096);
    s = _dropUnpairedSurrogates(s);
    s = s.replaceAll(_controls, '');
    s = s.replaceAll(_invisible, '');
    s = String.fromCharCodes(s.runes.where((r) => !_isAstralInvisible(r)));
    s = s.replaceAll(_reserved, '_');
    s = s.replaceAll(_spaces, ' ').trim();
    // No hidden files, no "-option" names; Windows drops trailing dots/spaces.
    s = s.replaceFirst(RegExp(r'^[.\s-]+'), '');
    s = s.replaceFirst(RegExp(r'[.\s]+$'), '');

    final ext = forceExtension?.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (s.isEmpty) s = _fallback(fallback);

    var stem = s;
    var extension = '';
    if (ext != null && ext.isNotEmpty) {
      if (s.toLowerCase().endsWith('.$ext') && s.length > ext.length + 1) {
        stem = s.substring(0, s.length - ext.length - 1);
      }
      extension = '.$ext';
    } else {
      final dot = s.lastIndexOf('.');
      if (dot > 0 && s.length - dot <= 11 && !s.substring(dot + 1).contains(' ')) {
        stem = s.substring(0, dot);
        extension = s.substring(dot);
      }
    }
    stem = stem.replaceFirst(RegExp(r'[.\s]+$'), '');
    if (stem.isEmpty) stem = _fallback(fallback);

    final baseName = stem.split('.').first;
    if (_windowsDevice.hasMatch(baseName.trim())) stem = '_$stem';

    final extBytes = utf8.encode(extension).length;
    stem = _truncateUtf8(stem, maxBytes - extBytes).replaceFirst(RegExp(r'[.\s]+$'), '');
    if (stem.isEmpty) stem = '_';
    return '$stem$extension';
  }

  /// Sanitizes [name] and returns the absolute path of it inside [dir].
  /// Throws [UnsafePathException] if the result would not be a direct child of
  /// [dir] or if an existing entry at that path is a symlink.
  static String childPath(Directory dir, String? name, {String? forceExtension}) {
    final safe = sanitize(name, forceExtension: forceExtension);
    final root = p.normalize(p.absolute(dir.path));
    final candidate = p.normalize(p.join(root, safe));
    if (p.dirname(candidate) != root || !p.isWithin(root, candidate)) {
      throw UnsafePathException('name escapes target directory');
    }
    if (FileSystemEntity.isLinkSync(candidate)) {
      throw UnsafePathException('target is a symbolic link');
    }
    return candidate;
  }

  /// Like [childPath] but never returns an existing path: appends ` (2)`,
  /// ` (3)`... to the stem until the name is free.
  static String uniqueChildPath(Directory dir, String? name, {String? forceExtension, int maxTries = 10000}) {
    final first = childPath(dir, name, forceExtension: forceExtension);
    if (FileSystemEntity.typeSync(first, followLinks: false) == FileSystemEntityType.notFound) return first;
    final base = p.basename(first);
    final ext = p.extension(base);
    final stem = base.substring(0, base.length - ext.length);
    for (var i = 2; i <= maxTries; i++) {
      final suffix = ' ($i)';
      final trimmed = _truncateUtf8(stem, maxUtf8Bytes - utf8.encode('$suffix$ext').length);
      final candidate = childPath(dir, '$trimmed$suffix$ext');
      if (FileSystemEntity.typeSync(candidate, followLinks: false) == FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    throw const UnsafePathException('no free file name');
  }

  static String _fallback(String fallback) {
    if (fallback == defaultFallback || fallback.isEmpty) return defaultFallback;
    // Sanitize caller-provided fallbacks too (terminates: defaultFallback is safe).
    final f = sanitize(fallback, fallback: defaultFallback);
    return f.isEmpty ? defaultFallback : f;
  }

  static bool _isAstralInvisible(int r) =>
      (r >= 0xE0000 && r <= 0xE007F) || // tag characters
      (r >= 0xE0100 && r <= 0xE01EF) || // variation selectors supplement
      (r >= 0x1D173 && r <= 0x1D17A) || // musical formatting
      (r >= 0xF0000); // private use planes

  static String _dropUnpairedSurrogates(String s) {
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0xD800 && c <= 0xDBFF) {
        if (i + 1 < s.length) {
          final d = s.codeUnitAt(i + 1);
          if (d >= 0xDC00 && d <= 0xDFFF) {
            b.writeCharCode(c);
            b.writeCharCode(d);
            i++;
            continue;
          }
        }
        continue; // lone high surrogate
      }
      if (c >= 0xDC00 && c <= 0xDFFF) continue; // lone low surrogate
      b.writeCharCode(c);
    }
    return b.toString();
  }

  /// Cuts [s] to at most [maxBytes] UTF-8 bytes without splitting a code point.
  static String _truncateUtf8(String s, int maxBytes) {
    if (maxBytes <= 0) return '';
    if (utf8.encode(s).length <= maxBytes) return s;
    final b = StringBuffer();
    var used = 0;
    for (final r in s.runes) {
      final n = r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4;
      if (used + n > maxBytes) break;
      b.writeCharCode(r);
      used += n;
    }
    return b.toString();
  }
}

/// Containment checks for paths that must stay inside app-controlled dirs.
abstract final class PathGuard {
  /// True if [candidate] is [root] itself or inside it, comparing normalized
  /// absolute paths. With [resolveLinks], existing paths are resolved to their
  /// real location first (so a symlink inside [root] pointing outside fails).
  static bool isInside(String root, String candidate, {bool resolveLinks = true}) {
    var r = p.normalize(p.absolute(root));
    var c = p.normalize(p.absolute(candidate));
    if (resolveLinks) {
      r = _real(r);
      c = _real(c);
    }
    return p.equals(r, c) || p.isWithin(r, c);
  }

  static String _real(String path) {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) {
        // Resolve the deepest existing parent so `root/link/new.pdf` is caught.
        final parent = p.dirname(path);
        if (parent == path) return path;
        return p.join(_real(parent), p.basename(path));
      }
      return p.normalize(File(path).resolveSymbolicLinksSync());
    } on FileSystemException {
      return path;
    }
  }
}
