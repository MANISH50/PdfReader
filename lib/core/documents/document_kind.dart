import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// What kind of document a file is. PDFs open in the viewer; everything else
/// opens in the read-only reader (features/reader).
enum DocumentKind { pdf, docx, markdown, text, sheet }

/// Bytes scanned for the `%PDF-` marker (same as the PDF service).
const int kPdfHeaderScanBytes = 1024;

/// Bytes decoded to decide whether an unknown file is text.
const int kTextSniffBytes = 64 * 1024;

/// ZIP entries we look through for `word/document.xml` while sniffing.
const int kMaxSniffZipEntries = 2000;

/// Delimited-text extensions shown as a table.
const delimitedExtensions = {'.csv', '.tsv', '.tab'};

/// Macro-enabled Office files are never opened.
const _macroExtensions = {'.docm', '.dotm', '.xlsm', '.xltm', '.xlam', '.xlsb'};

const _markdownExtensions = {'.md', '.markdown', '.mdown', '.mkd', '.mkdn'};

/// Extensions shown in a monospace font (data, logs, source code).
const codeLikeExtensions = {
  '.json', '.jsonl', '.ndjson', '.xml', '.yaml', '.yml', '.csv', '.tsv', '.log', '.ini', '.cfg', '.conf',
  '.toml', '.properties', '.env', '.sql', '.sh', '.bash', '.zsh', '.bat', '.ps1', '.dart', '.java', '.kt',
  '.kts', '.swift', '.m', '.mm', '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.go', '.rs', '.py', '.rb', '.php',
  '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.html', '.htm', '.css', '.scss', '.less', '.vue', '.lua',
  '.pl', '.r', '.scala', '.gradle', '.diff', '.patch', '.gitignore', '.dockerfile', '.makefile', '.srt',
};

/// Lower-case extension of [displayName] (or [path] when there is no name).
String documentExtension(String path, {String? displayName}) {
  final n = (displayName == null || displayName.trim().isEmpty) ? path : displayName.trim();
  return p.extension(n).toLowerCase();
}

bool isCodeLikeName(String name) => codeLikeExtensions.contains(p.extension(name).toLowerCase());

bool hasPdfMarker(List<int> head) {
  final n = head.length < kPdfHeaderScanBytes ? head.length : kPdfHeaderScanBytes;
  for (var i = 0; i + 5 <= n; i++) {
    if (head[i] == 0x25 && head[i + 1] == 0x50 && head[i + 2] == 0x44 && head[i + 3] == 0x46 && head[i + 4] == 0x2D) {
      return true;
    }
  }
  return false;
}

bool hasZipMagic(List<int> head) =>
    head.length >= 4 && head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04;

/// Detects the kind of the file at [path]. Returns null for unsupported files.
///
/// Order: `%PDF-` in the first 1024 bytes → pdf; ZIP with `word/document.xml`
/// (central directory only, nothing is decompressed) → docx; ZIP with
/// `xl/workbook.xml` → sheet; `.csv`/`.tsv` text → sheet; Markdown
/// extension → markdown; first 64 KiB decodes as text → text.
Future<DocumentKind?> sniffDocumentKind(String path, {String? displayName}) async {
  final file = File(path);
  final RandomAccessFile raf;
  try {
    raf = await file.open();
  } on FileSystemException {
    return null;
  }
  final Uint8List head;
  try {
    head = await raf.read(kTextSniffBytes);
  } on FileSystemException {
    return null;
  } finally {
    await raf.close();
  }
  final ext = documentExtension(path, displayName: displayName);
  if (hasPdfMarker(head)) return DocumentKind.pdf;
  if (hasZipMagic(head)) {
    if (_macroExtensions.contains(ext)) return null;
    return switch (zipOfficeKind(path)) {
      'word/document.xml' => DocumentKind.docx,
      'xl/workbook.xml' => DocumentKind.sheet,
      _ => null,
    };
  }
  if (!looksLikeText(head)) return null;
  if (_markdownExtensions.contains(ext)) return DocumentKind.markdown;
  if (delimitedExtensions.contains(ext)) return DocumentKind.sheet;
  return DocumentKind.text;
}

/// Whether the ZIP at [path] has a `word/document.xml` entry.
bool zipHasWordDocument(String path) => zipOfficeKind(path) == 'word/document.xml';

/// The main part of an Office ZIP at [path]: `word/document.xml` (Word) or
/// `xl/workbook.xml` (Excel), else null. Reads only the central directory,
/// at most [kMaxSniffZipEntries] entries.
String? zipOfficeKind(String path) {
  InputFileStream? input;
  try {
    input = InputFileStream(path);
    var n = 0;
    for (final h in ZipDirectory().headers(input, files: false)) {
      if (h.filename == 'word/document.xml' || h.filename == 'xl/workbook.xml') return h.filename;
      if (++n >= kMaxSniffZipEntries) break;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      input?.closeSync();
    } catch (_) {}
  }
}

/// Decodes [bytes] as text: UTF-8 (optional BOM) or UTF-16 with a BOM.
/// Returns null if it isn't valid text. With [lenient], malformed UTF-8 is
/// replaced instead of rejected (used for the part beyond the sniffed head).
String? decodeText(Uint8List bytes, {bool lenient = false}) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes, 2, littleEndian: true);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes, 2, littleEndian: false);
  var start = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) start = 3;
  final view = Uint8List.sublistView(bytes, start);
  if (lenient) return const Utf8Decoder(allowMalformed: true).convert(view);
  try {
    return const Utf8Decoder().convert(view);
  } on FormatException {
    return null;
  }
}

String _utf16(Uint8List b, int start, {required bool littleEndian}) {
  final n = (b.length - start) ~/ 2;
  final units = Uint16List(n);
  for (var i = 0; i < n; i++) {
    final lo = b[start + 2 * i], hi = b[start + 2 * i + 1];
    units[i] = littleEndian ? (hi << 8 | lo) : (lo << 8 | hi);
  }
  return String.fromCharCodes(units);
}

/// True if [head] (the first bytes of a file) decodes as text with fewer than
/// 1% control characters (tab, newline, carriage return and form feed allowed).
bool looksLikeText(Uint8List head) {
  String? text = decodeText(head);
  if (text == null && head.length >= kTextSniffBytes) {
    // The scan window may cut a multi-byte UTF-8 sequence in half.
    for (var cut = 1; cut <= 3 && text == null; cut++) {
      text = decodeText(Uint8List.sublistView(head, 0, head.length - cut));
    }
  }
  if (text == null) return false;
  if (text.isEmpty) return true;
  var control = 0;
  for (final c in text.codeUnits) {
    if ((c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D && c != 0x0C) || c == 0x7F) control++;
  }
  return control * 100 < text.length;
}
