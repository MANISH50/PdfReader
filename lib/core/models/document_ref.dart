import 'package:path/path.dart' as p;

/// A reference to a PDF the user opened. [path] always points to a file in
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
  });

  final String id;
  final String path;
  final String displayName;
  final int sizeBytes;

  /// Original content:// or file:// URI, when the file came from another app.
  final String? sourceUri;

  String get baseName => p.basenameWithoutExtension(displayName);

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'displayName': displayName,
        'sizeBytes': sizeBytes,
        'sourceUri': sourceUri,
      };

  factory DocumentRef.fromJson(Map<String, Object?> j) => DocumentRef(
        id: j['id']! as String,
        path: j['path']! as String,
        displayName: j['displayName']! as String,
        sizeBytes: (j['sizeBytes']! as num).toInt(),
        sourceUri: j['sourceUri'] as String?,
      );

  @override
  bool operator ==(Object other) => other is DocumentRef && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
