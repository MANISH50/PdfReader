// Engine robustness tests: every corpus file is opened with the real PDFium
// (pdfrx) under `flutter test`. Valid files must work; malformed and fuzzed
// files must either open safely or throw - never hang past the timeout or
// take the process down.
//
// A crash inside PDFium kills the whole test process. To find the culprit,
// read build/qa/corpus_progress.log: the last "START" line without a matching
// "END" is the file that crashed. Results go to build/qa/corpus_results.json.
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/core/security/limits.dart';
import 'package:pdfreader/core/security/link_policy.dart';
import 'package:pdfrx/pdfrx.dart';

import '../helpers/corpus.dart';

/// Outcome of probing one file.
class Probe {
  Probe(this.entry);
  final CorpusEntry entry;
  bool opened = false;
  int? pageCount;
  bool rendered = false;
  String? text;
  Object? error;
  String? stage; // stage that failed / hung
  bool hung = false;
  final timings = <String, int>{};

  Map<String, Object?> toJson() => {
        'path': entry.path,
        'expect': entry.expect.name,
        'opened': opened,
        'pages': pageCount,
        'rendered': rendered,
        'textChars': text?.length,
        if (error != null) 'error': '${error.runtimeType}: ${_short(error.toString())}',
        if (stage != null) 'failedStage': stage,
        'hung': hung,
        'ms': timings,
      };
}

String _short(String s) => s.length > 200 ? '${s.substring(0, 200)}...' : s;

class _Hang implements Exception {
  _Hang(this.stage, this.limit);
  final String stage;
  final Duration limit;
  @override
  String toString() => 'HANG in $stage (> ${limit.inSeconds}s)';
}

/// Timeouts mirror the app's SecurityLimits.
Future<T> _timed<T>(Probe pr, String stage, Duration limit, Future<T> Function() f) async {
  final sw = Stopwatch()..start();
  try {
    return await f().timeout(limit, onTimeout: () => throw _Hang(stage, limit));
  } finally {
    pr.timings[stage] = sw.elapsedMilliseconds;
  }
}

/// Render width used for "page 1 at small size".
const _thumbWidth = 160.0;

Future<Probe> probe(CorpusEntry e, {String? password, bool tryText = true}) async {
  final pr = Probe(e);
  PdfDocument? doc;
  var stage = 'open';
  try {
    final PdfDocument d = await _timed(pr, 'open', SecurityLimits.openTimeout, () {
      return PdfDocument.openFile(
        e.absolutePath,
        passwordProvider: password == null ? null : createSimplePasswordProvider(password),
        firstAttemptByEmptyPassword: password == null,
      );
    });
    doc = d;
    pr.opened = true;
    stage = 'pages';
    pr.pageCount = d.pages.length;
    if (pr.pageCount! > 0) {
      final page = d.pages.first;
      stage = 'render';
      final w = page.width.isFinite && page.width > 0 ? page.width : 1.0;
      final h = page.height.isFinite && page.height > 0 ? page.height : 1.0;
      final fullH = (_thumbWidth * h / w).clamp(1.0, 4000.0);
      final img = await _timed(pr, 'render', SecurityLimits.pageRenderTimeout, () {
        return page.render(
          width: _thumbWidth.toInt(),
          height: fullH.toInt(),
          fullWidth: _thumbWidth,
          fullHeight: fullH,
        );
      });
      pr.rendered = img != null;
      img?.dispose();
      if (tryText) {
        stage = 'text';
        final t = await _timed(pr, 'text', SecurityLimits.pageTextTimeout, page.loadText);
        pr.text = t?.fullText ?? '';
      }
    }
  } on _Hang catch (h) {
    pr
      ..hung = true
      ..stage = h.stage
      ..error = h;
  } catch (err) {
    pr
      ..error = err
      ..stage = stage;
  } finally {
    if (doc != null) {
      try {
        await doc.dispose().timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
  }
  return pr;
}

void main() {
  final corpus = Corpus.load();
  final results = <Probe>[];
  final outDir = Directory('build/qa')..createSync(recursive: true);
  final log = File('${outDir.path}/corpus_progress.log').openSync(mode: FileMode.write);
  // Once PDFium hangs on its worker, later calls queue behind it; skip them.
  Probe? firstHang;

  void logLine(String s) {
    log.writeStringSync('${DateTime.now().toIso8601String()} $s\n');
    log.flushSync();
  }

  Future<Probe> run(CorpusEntry e, {String? password}) async {
    if (firstHang != null) {
      markTestSkipped('PDFium blocked by earlier hang in ${firstHang!.entry}');
      return Probe(e)..stage = 'skipped';
    }
    logLine('START ${e.path}${password == null ? '' : ' (password)'}');
    final pr = await probe(e, password: password);
    logLine('END   ${e.path} opened=${pr.opened} pages=${pr.pageCount} rendered=${pr.rendered} '
        'error=${pr.error == null ? '-' : pr.error.runtimeType} ms=${pr.timings}');
    results.add(pr);
    if (pr.hung) firstHang = pr;
    return pr;
  }

  setUpAll(initPdfrxForTests);

  tearDownAll(() {
    final hangs = results.where((r) => r.hung).map((r) => '${r.entry} (${r.stage})').toList();
    final summary = {
      'pdfium': 'pdfrx 2.12.1 / pdfrx_engine 0.9.2',
      'total': results.length,
      'opened': results.where((r) => r.opened).length,
      'failedGracefully': results.where((r) => !r.opened && !r.hung).length,
      'hangs': hangs,
      'maxRssMB': ProcessInfo.maxRss ~/ (1024 * 1024),
      'files': [for (final r in results) r.toJson()],
    };
    File('${outDir.path}/corpus_results.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
    logLine('DONE total=${results.length} hangs=$hangs');
    log.closeSync();
    // ignore: avoid_print
    print('corpus: ${summary['total']} probes, ${summary['opened']} opened, '
        '${summary['failedGracefully']} failed gracefully, hangs: $hangs');
  });

  group('valid files', () {
    for (final e in corpus.entries.where((e) => e.expect == Expect.opens)) {
      if (e.path == 'huge.pdf') continue; // measured separately below
      test(e.path, () async {
        final pr = await run(e);
        expect(pr.hung, isFalse, reason: '$e hung in ${pr.stage}');
        expect(pr.error, isNull, reason: '$e: ${pr.error}');
        expect(pr.opened, isTrue);
        if (e.pages != null) expect(pr.pageCount, e.pages);
        expect(pr.rendered, isTrue, reason: 'page 1 must render');
        for (final t in e.text) {
          expect(pr.text, contains(t), reason: 'text of $e page 1');
        }
        final ranges = e.features['codepointRanges'] as List?;
        if (ranges != null) {
          for (final r in ranges.cast<List<Object?>>()) {
            final lo = r[0] as int, hi = r[1] as int;
            expect(pr.text!.runes.any((c) => c >= lo && c <= hi), isTrue,
                reason: '$e text must contain U+${lo.toRadixString(16)}..U+${hi.toRadixString(16)}');
          }
        }
        if (e.features['textLayer'] == false) {
          expect(pr.text!.trim(), isEmpty, reason: 'scanned file has no text layer');
        }
      });
    }
  });

  group('protected files', () {
    for (final e in corpus.entries.where((e) => e.expect == Expect.needsPassword)) {
      test('${e.path}: no password -> PdfPasswordException', () async {
        final pr = await run(e);
        expect(pr.hung, isFalse);
        expect(pr.opened, isFalse);
        expect(pr.error, isA<PdfPasswordException>());
      });
      test('${e.path}: wrong password -> PdfPasswordException', () async {
        final pr = await run(e, password: 'wrong-password');
        expect(pr.opened, isFalse);
        expect(pr.error, isA<PdfPasswordException>());
      });
      test('${e.path}: correct password opens', () async {
        final pr = await run(e, password: e.password);
        expect(pr.error, isNull, reason: '${pr.error}');
        expect(pr.pageCount, e.pages);
        for (final t in e.text) {
          expect(pr.text, contains(t));
        }
      });
    }
    test('owner-only-protected.pdf exposes restricted permissions', () async {
      await initPdfrxForTests();
      final doc = await PdfDocument.openFile(corpus.byPath('owner-only-protected.pdf').absolutePath);
      try {
        expect(doc.isEncrypted, isTrue);
        expect(doc.permissions?.allowsCopying, isFalse);
        expect(doc.permissions?.allowsPrinting, isFalse);
      } finally {
        await doc.dispose();
      }
    });
  });

  group('text_multi.pdf features', () {
    late PdfDocument doc;
    final e = corpus.byPath('text_multi.pdf');
    setUpAll(() async {
      await initPdfrxForTests();
      doc = await PdfDocument.openFile(e.absolutePath);
    });
    tearDownAll(() => doc.dispose());

    test('outline has every chapter', () async {
      final outline = await doc.loadOutline();
      expect(outline.length, e.features['outlineTopLevel']);
      expect(outline[1].children.length, 3);
    });

    test('search term appears on the expected pages only', () async {
      final search = e.features['search']! as Map<String, Object?>;
      final hits = <int>[];
      for (final page in doc.pages) {
        final t = await page.loadText();
        if (t!.fullText.contains(search['term']! as String)) hits.add(page.pageNumber);
      }
      expect(hits, search['pages']);
    });

    test('links: internal ones resolve, javascript: is blocked by LinkPolicy', () async {
      final links = await doc.pages.first.loadLinks(enableAutoLinkDetection: false);
      final internal = links.where((l) => l.dest != null).toList();
      expect(internal.length, greaterThanOrEqualTo(19));
      final urls = links.map((l) => l.url).whereType<Uri>().toList();
      expect(urls.any((u) => u.toString() == 'https://example.com/pdfreader'), isTrue);
      for (final u in urls) {
        final d = LinkPolicy.decide(uri: u);
        if (u.scheme == 'https') {
          expect(d, LinkDecision.confirmExternal);
        } else {
          expect(d, LinkDecision.blocked, reason: '$u must be blocked');
        }
      }
    });
  });

  group('malformed files never hang or crash', () {
    for (final e in corpus.entries.where((e) => e.category == 'malformed')) {
      test(e.path, () async {
        final pr = await run(e);
        expect(pr.hung, isFalse, reason: '$e hung in ${pr.stage} - SECURITY: report to Security agent');
        if (e.expect == Expect.fails) {
          expect(pr.opened, isFalse, reason: '$e must be rejected');
          expect(pr.error, isA<PdfException>(), reason: 'engine error must be a PdfException: ${pr.error}');
        }
        if (pr.opened) {
          // Opened documents must stay within the app's limits or be rejectable by them.
          expect(pr.pageCount, isNotNull);
        }
      });
    }
  });

  group('fuzz files never hang or crash', () {
    for (final e in corpus.where('fuzz')) {
      test(e.path, () async {
        final pr = await run(e);
        expect(pr.hung, isFalse, reason: '$e hung in ${pr.stage} - SECURITY: report to Security agent');
      });
    }
  });

  group('performance', () {
    Future<void> measure(CorpusEntry e) async {
      final sw = Stopwatch()..start();
      final doc = await PdfDocument.openFile(e.absolutePath);
      final openMs = sw.elapsedMilliseconds;
      final page = doc.pages.first;
      final img = await page.render(
        width: 1080,
        height: (1080 * page.height / page.width).round(),
        fullWidth: 1080,
        fullHeight: 1080 * page.height / page.width,
      );
      final firstPageMs = sw.elapsedMilliseconds;
      img?.dispose();
      final pages = doc.pages.length;
      await doc.dispose();
      final line = 'PERF ${e.path}: pages=$pages open=${openMs}ms open+firstPage(1080px)=${firstPageMs}ms';
      // ignore: avoid_print
      print(line);
      File('build/qa/perf_host.txt').writeAsStringSync('$line\n', mode: FileMode.append);
      // Host numbers are informational (shared CPUs vary); the < 2 s target is
      // enforced on devices by integration_test/performance_test.dart.
      // Generous bound here only catches pathological regressions.
      expect(firstPageMs, lessThan(15000), reason: 'first page pathologically slow');
    }

    test('text_multi.pdf open + first page', () async {
      await initPdfrxForTests();
      await measure(corpus.byPath('text_multi.pdf'));
    });

    final huge = [
      ...corpus.entries.where((e) => e.path == 'huge.pdf'),
      ...[
        for (final dir in [Platform.environment['QA_HUGE_DIR'] ?? ''])
          if (dir.isNotEmpty && File('$dir/manifest.json').existsSync())
            ...Corpus.load(dir).entries.where((e) => e.path == 'huge.pdf')
      ],
    ];
    test('huge.pdf open + first page (only when generated with --huge)', () async {
      await initPdfrxForTests();
      await measure(huge.first);
    }, skip: huge.isEmpty ? 'set QA_HUGE_DIR to a corpus dir generated with make_corpus.py --huge' : false);
  });
}
