import 'dart:async';

/// A file another app handed to us (open-with, share, "Open in").
class IncomingFile {
  const IncomingFile({required this.path, this.displayName, this.sourceUri});
  final String path;
  final String? displayName;
  final String? sourceUri;
}

/// Delivers files from VIEW/SEND intents (Android) and Open-in / share (iOS).
/// Files are always copied into app-private inbox storage before use.
abstract interface class IncomingFileService {
  /// File that launched the app, if any (consumed once).
  Future<IncomingFile?> initialFile();

  /// Files received while running.
  Stream<IncomingFile> get files;
}

abstract interface class ShareService {
  Future<void> shareFiles(List<String> paths, {String? subject});
}

/// Picks files with the system picker only (no broad storage permission).
abstract interface class FilePickService {
  Future<List<String>> pickPdfs({bool multiple = false});

  /// Picks one document of any supported kind (PDF, DOCX, Markdown, text).
  /// The file is sniffed on import; unsupported files are refused there.
  Future<List<String>> pickDocuments();

  /// Lets the user choose where to save (SAF create document / iOS export).
  /// Returns the destination description, or null if cancelled.
  Future<String?> saveAs(String sourcePath, {required String suggestedName});
}
