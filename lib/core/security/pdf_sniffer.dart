import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../pdf/document_service.dart';
import 'limits.dart';
import 'safe_filename.dart';

/// Why a file was rejected before it reached the PDF engine.
enum SniffFailure {
  notFound,

  /// A directory, socket, pipe, device... anything but a regular file.
  notAFile,

  /// A symlink (or a path) that resolves outside the allowed directories.
  outsideAllowedDirs,
  empty,
  tooLarge,

  /// No `%PDF-` marker in the first [PdfSniffer.headerWindow] bytes.
  notPdf,
  unreadable;

  /// Maps to the user-facing [OpenFailure] categories.
  OpenFailure get openFailure => switch (this) {
        SniffFailure.notFound || SniffFailure.notAFile || SniffFailure.outsideAllowedDirs ||
        SniffFailure.unreadable =>
          OpenFailure.notFound,
        SniffFailure.tooLarge => OpenFailure.tooLarge,
        SniffFailure.empty || SniffFailure.notPdf => OpenFailure.notPdf,
      };
}

/// Result of [PdfSniffer.sniffFile] / [PdfSniffer.sniffBytes].
class SniffResult {
  const SniffResult._({this.failure, this.sizeBytes = 0, this.headerOffset = -1, this.resolvedPath});

  /// Null when the file looks like a PDF.
  final SniffFailure? failure;
  final int sizeBytes;

  /// Byte offset of `%PDF-` (PDF readers tolerate leading garbage up to 1 KiB).
  final int headerOffset;

  /// Real path after resolving symlinks; use this (not the input path) to open.
  final String? resolvedPath;

  bool get ok => failure == null;

  /// Throws [DocumentOpenException] unless [ok].
  void throwIfFailed() {
    final f = failure;
    if (f != null) throw DocumentOpenException(f.openFailure, f.name);
  }

  @override
  String toString() => ok ? 'SniffResult(ok, $sizeBytes bytes, header@$headerOffset)' : 'SniffResult($failure)';
}

/// Cheap pre-checks before handing an untrusted file to PDFium.
abstract final class PdfSniffer {
  static const int headerWindow = 1024;
  static const List<int> _magic = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-

  /// Offset of `%PDF-` within the first [headerWindow] bytes, or -1.
  static int findHeader(List<int> bytes) {
    final end = (bytes.length < headerWindow ? bytes.length : headerWindow) - _magic.length;
    outer:
    for (var i = 0; i <= end; i++) {
      for (var j = 0; j < _magic.length; j++) {
        if (bytes[i + j] != _magic[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static SniffResult sniffBytes(Uint8List bytes, {int maxBytes = SecurityLimits.maxFileBytes}) {
    if (bytes.isEmpty) return const SniffResult._(failure: SniffFailure.empty);
    if (bytes.length > maxBytes) return SniffResult._(failure: SniffFailure.tooLarge, sizeBytes: bytes.length);
    final off = findHeader(bytes);
    if (off < 0) return SniffResult._(failure: SniffFailure.notPdf, sizeBytes: bytes.length);
    return SniffResult._(sizeBytes: bytes.length, headerOffset: off);
  }

  /// Checks [path] without trusting it:
  /// - must be a regular file (directories, pipes, devices are rejected);
  /// - symlinks are followed only if the real target is inside [allowedRoots];
  ///   with no [allowedRoots], symlinks are rejected outright;
  /// - with [allowedRoots], the real path must be inside one of them;
  /// - size must be 1..[maxBytes] (measured on the opened handle);
  /// - `%PDF-` must appear in the first [headerWindow] bytes.
  static Future<SniffResult> sniffFile(
    String path, {
    List<String>? allowedRoots,
    int maxBytes = SecurityLimits.maxFileBytes,
  }) async {
    final abs = p.normalize(p.absolute(path));
    final FileSystemEntityType linkType;
    try {
      linkType = await FileSystemEntity.type(abs, followLinks: false);
    } on FileSystemException {
      return const SniffResult._(failure: SniffFailure.unreadable);
    }
    if (linkType == FileSystemEntityType.notFound) {
      // dart:io reports device files (/dev/zero…) as notFound although they exist.
      final exists = await File(abs).exists();
      return SniffResult._(failure: exists ? SniffFailure.notAFile : SniffFailure.notFound);
    }

    String real;
    try {
      real = p.normalize(await File(abs).resolveSymbolicLinks());
    } on FileSystemException {
      // Dangling symlink or unreadable parent.
      return SniffResult._(
          failure: linkType == FileSystemEntityType.link ? SniffFailure.notFound : SniffFailure.unreadable);
    }

    if (allowedRoots == null) {
      if (linkType == FileSystemEntityType.link) {
        return const SniffResult._(failure: SniffFailure.outsideAllowedDirs);
      }
    } else if (!allowedRoots.any((root) => PathGuard.isInside(root, real))) {
      return const SniffResult._(failure: SniffFailure.outsideAllowedDirs);
    }

    final type = await FileSystemEntity.type(real, followLinks: false);
    if (type != FileSystemEntityType.file) return const SniffResult._(failure: SniffFailure.notAFile);

    RandomAccessFile? raf;
    try {
      raf = await File(real).open();
      final size = await raf.length();
      if (size == 0) return SniffResult._(failure: SniffFailure.empty, resolvedPath: real);
      if (size > maxBytes) return SniffResult._(failure: SniffFailure.tooLarge, sizeBytes: size, resolvedPath: real);
      final head = await raf.read(headerWindow);
      final off = findHeader(head);
      if (off < 0) return SniffResult._(failure: SniffFailure.notPdf, sizeBytes: size, resolvedPath: real);
      return SniffResult._(sizeBytes: size, headerOffset: off, resolvedPath: real);
    } on FileSystemException {
      return const SniffResult._(failure: SniffFailure.unreadable);
    } finally {
      await raf?.close();
    }
  }
}
