import 'package:path/path.dart' as p;

import '../documents/document_kind.dart';

/// A reference to a document the user opened (a PDF, or a DOCX / Markdown /
/// text file shown in the reader; see [kind]). [path] always points to a file in
/// app-private storage or one the OS granted access to (picker / open-with).
/// [id] is a stable key used for per-file state (last page, zoom, bookmarks,
/// annotations): it is derived from file size + a hash of the first/last
/// 64 KiB, so it survives renames and re-imports of the same file.
class DocumentRef {
  const DocumentRef({
    required this.id,
    required this.path,
    required this.displayName,
    required this.sizeBytes,
    this.sourceUri,
    this.kind = DocumentKind.pdf,
  });

  final String id;
  final String path;
  final String displayName;
  final int sizeBytes;

  /// Original content:// or file:// URI, when the file came from another app.
  final String? sourceUri;

  /// Missing in JSON written by older versions: those were always PDFs.
  final DocumentKind kind;

  bool get isPdf => kind == DocumentKind.pdf;

  String get baseName => p.basenameWithoutExtension(displayName);

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'displayName': displayName,
        'sizeBytes': sizeBytes,
        'sourceUri': sourceUri,
        'kind': kind.name,
      };

  factory DocumentRef.fromJson(Map<String, Object?> j) => DocumentRef(
        id: j['id']! as String,
        path: j['path']! as String,
        displayName: j['displayName']! as String,
        sizeBytes: (j['sizeBytes']! as num).toInt(),
        sourceUri: j['sourceUri'] as String?,
        kind: DocumentKind.values.asNameMap()[j['kind']] ?? DocumentKind.pdf,
      );

  @override
  bool operator ==(Object other) => other is DocumentRef && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
