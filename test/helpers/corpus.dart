import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

/// Test PDF corpus produced by `tool/testdata/make_corpus.py`.
///
/// The committed corpus lives in `test_assets/pdfs/`. Override with the
/// `QA_CORPUS_DIR` environment variable (e.g. `build/corpus` after running the
/// generator with `--huge`).
class Corpus {
  Corpus(this.dir, this.entries);

  final Directory dir;
  final List<CorpusEntry> entries;

  static const defaultDir = 'test_assets/pdfs';

  static Corpus load([String? path]) {
    final dir = Directory(path ?? Platform.environment['QA_CORPUS_DIR'] ?? defaultDir);
    final manifest = File(p.join(dir.path, 'manifest.json'));
    if (!manifest.existsSync()) {
      throw StateError('No corpus manifest at ${manifest.path}. Run tool/testdata/make_corpus.py (see TESTING.md).');
    }
    final json = jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    final files = [
      for (final f in json['files']! as List)
        CorpusEntry.fromJson(f as Map<String, Object?>, dir.path),
    ];
    return Corpus(dir, files.where((e) => File(e.absolutePath).existsSync()).toList());
  }

  CorpusEntry byPath(String rel) => entries.firstWhere((e) => e.path == rel);

  Iterable<CorpusEntry> where(String category) => entries.where((e) => e.category == category);
}

enum Expect { opens, needsPassword, fails, failsOrOpens }

class CorpusEntry {
  CorpusEntry({
    required this.path,
    required this.absolutePath,
    required this.category,
    required this.expect,
    required this.description,
    this.failure,
    this.password,
    this.pages,
    this.text = const [],
    this.features = const {},
  });

  factory CorpusEntry.fromJson(Map<String, Object?> j, String root) => CorpusEntry(
        path: j['path']! as String,
        absolutePath: p.join(root, j['path']! as String),
        category: j['category']! as String,
        expect: switch (j['expect']) {
          'opens' => Expect.opens,
          'needs_password' => Expect.needsPassword,
          'fails' => Expect.fails,
          _ => Expect.failsOrOpens,
        },
        description: j['description'] as String? ?? '',
        failure: j['failure'] as String?,
        password: j['password'] as String?,
        pages: (j['pages'] as num?)?.toInt(),
        text: [for (final t in (j['text'] as List?) ?? const []) t as String],
        features: (j['features'] as Map<String, Object?>?) ?? const {},
      );

  final String path;
  final String absolutePath;
  final String category;
  final Expect expect;
  final String description;

  /// Expected `OpenFailure` name when the file fails to open.
  final String? failure;
  final String? password;
  final int? pages;
  final List<String> text;
  final Map<String, Object?> features;

  @override
  String toString() => path;
}

bool _pdfrxReady = false;

/// Initialises pdfrx for `flutter test` on the host (Linux/macOS/Windows).
///
/// `flutter test` builds pdfium_dart's native asset (PDFium binary from
/// bblanchon/pdfium-binaries, SHA-256 pinned) into
/// `build/native_assets/<os>/`, and the pure-Dart `pdfrxInitialize()` loads it.
/// `pdfrxFlutterInitialize()` cannot be used in unit tests because it calls
/// path_provider, which has no host implementation under `flutter test`.
Future<void> initPdfrxForTests() async {
  if (_pdfrxReady) return;
  Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.createTempSync('pdfrx_test_cache').path;
  await pdfrxInitialize();
  _pdfrxReady = true;
}
