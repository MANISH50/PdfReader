import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pdf/document_service.dart';

/// Decompression-bomb pre-scan, run before PDFium sees an untrusted file.
///
/// Why: PDFium runs in our process and has no allocation-limit API
/// (FPDF_LIBRARY_CONFIG only configures fonts, V8 and the renderer), so a
/// 2 KB PDF whose `[/FlateDecode /FlateDecode]` stream inflates to 1 GB makes
/// it allocate gigabytes and the OS kills the app on low-RAM phones.
///
/// How: in a background isolate, find every `stream` in the file, parse its
/// dictionary (/Filter, /Length, image /Width /Height…), and *count* the bytes
/// its Flate filter chain would produce, aborting at a cap. Nothing decoded is
/// kept: memory stays at a few hundred KB regardless of file size.
///
/// Fast path: a single Flate layer expands at most ~1032:1, so a stream whose
/// worst case (`raw length x 1032^layers`) is below the cap is skipped without
/// inflating. Most content streams and fonts in real files take this path;
/// only large or multi-layer streams are inflated, worst-first.
enum PrescanVerdict {
  /// Nothing suspicious found.
  ok,

  /// Refuse to open: show "This file looks unsafe or too complex to open".
  unsafe,

  /// Ran out of time budget before checking every risky stream. The file
  /// was not proven safe; the caller decides (we open it, see SECURITY_NOTES).
  incomplete,
}

enum PrescanIssue {
  /// One stream decodes past its cap.
  decompressionBomb,

  /// More than one amplifying filter we cannot verify (LZW / RunLength) in a chain.
  unverifiableNestedCompression,

  /// Image whose declared size alone exceeds [PrescanLimits.maxImageBytes].
  oversizedImage,

  /// Absurd number of streams.
  tooManyStreams,
}

class PrescanLimits {
  const PrescanLimits({
    this.maxStreamBytes = 64 * 1024 * 1024,
    this.maxImageBytes = 512 * 1024 * 1024,
    this.maxStreams = 500000,
    this.timeBudget = const Duration(seconds: 8),
  });

  /// Decoded-size cap for any non-image stream (content, fonts, object streams).
  final int maxStreamBytes;

  /// Cap for image streams: decoded size may reach the size implied by
  /// /Width x /Height x components x bits (plus slack), up to this.
  final int maxImageBytes;
  final int maxStreams;
  final Duration timeBudget;
}

class PdfPrescanResult {
  const PdfPrescanResult({
    required this.verdict,
    this.issue,
    this.detail,
    required this.streams,
    required this.streamsInflated,
    required this.bytesInflated,
    required this.elapsed,
  });

  final PrescanVerdict verdict;
  final PrescanIssue? issue;

  /// Developer detail (object offset, sizes). Never show raw to users.
  final String? detail;
  final int streams;
  final int streamsInflated;
  final int bytesInflated;
  final Duration elapsed;

  bool get isUnsafe => verdict == PrescanVerdict.unsafe;

  /// User-facing text for an unsafe result.
  static const userMessage = 'This file looks unsafe or too complex to open.';

  /// Throws `DocumentOpenException(OpenFailure.unsafe)` when [isUnsafe].
  void throwIfUnsafe() {
    if (isUnsafe) throw DocumentOpenException(OpenFailure.unsafe, issue?.name);
  }

  @override
  String toString() => 'PdfPrescanResult($verdict${issue == null ? '' : ' $issue'}, streams=$streams, '
      'inflated=$streamsInflated/${bytesInflated}B, ${elapsed.inMilliseconds}ms${detail == null ? '' : ', $detail'})';
}

/// Scans [path] in a background isolate. Never throws for malformed input;
/// I/O errors produce [PrescanVerdict.incomplete].
Future<PdfPrescanResult> prescanPdf(String path, {PrescanLimits limits = const PrescanLimits()}) =>
    Isolate.run(() => prescanPdfSync(path, limits: limits));

/// Synchronous variant (call only off the UI isolate).
PdfPrescanResult prescanPdfSync(String path, {PrescanLimits limits = const PrescanLimits()}) {
  final sw = Stopwatch()..start();
  RandomAccessFile? raf;
  try {
    raf = File(path).openSync();
    return _Scanner(raf, limits, sw).run();
  } on FileSystemException catch (e) {
    return PdfPrescanResult(
        verdict: PrescanVerdict.incomplete,
        detail: 'io: ${e.osError?.errorCode}',
        streams: 0,
        streamsInflated: 0,
        bytesInflated: 0,
        elapsed: sw.elapsed);
  } finally {
    raf?.closeSync();
  }
}

// ---------------------------------------------------------------------------

/// Worst-case Flate expansion of one layer (deflate max ratio is ~1032:1).
const int _flateMaxRatio = 1032;

class _StreamInfo {
  _StreamInfo(this.dataStart, this.dataEnd, this.filters, this.imageBytes);
  final int dataStart;
  final int dataEnd; // exclusive
  final List<String> filters; // normalized: Flate, LZW, RL, AHx, A85, DCT, JPX, JBIG2, CCF, Crypt, other
  final int? imageBytes; // declared decoded size for images, if known
  int get rawLength => dataEnd - dataStart;
  int get flateLayers => filters.takeWhile((f) => f == 'Flate').length;

  /// Upper bound of decoded size through the leading Flate layers (saturating).
  double get worstCase => rawLength * math.pow(_flateMaxRatio, flateLayers).toDouble();
}

class _CapExceeded implements Exception {}

class _CountingSink implements Sink<List<int>> {
  _CountingSink(this.cap);
  final int cap;
  int count = 0;
  @override
  void add(List<int> data) {
    count += data.length;
    if (count > cap) throw _CapExceeded();
  }

  @override
  void close() {}
}

class _Scanner {
  _Scanner(this.raf, this.limits, this.sw) : length = raf.lengthSync();

  final RandomAccessFile raf;
  final PrescanLimits limits;
  final Stopwatch sw;
  final int length;

  static const _chunk = 1 << 20;
  static const _dictWindow = 64 * 1024;
  static final _streamKw = 'stream'.codeUnits;
  static final _endstreamKw = 'endstream'.codeUnits;

  PdfPrescanResult _result(PrescanVerdict v, int streams, int inflated, int bytes,
          {PrescanIssue? issue, String? detail}) =>
      PdfPrescanResult(
          verdict: v,
          issue: issue,
          detail: detail,
          streams: streams,
          streamsInflated: inflated,
          bytesInflated: bytes,
          elapsed: sw.elapsed);

  bool get _overBudget => sw.elapsed > limits.timeBudget;

  PdfPrescanResult run() {
    final streams = <_StreamInfo>[];
    var cursor = 0;
    var count = 0;
    // Pass 1: index streams (sequential read, 1 MiB chunks).
    while (true) {
      final kw = _find(_streamKw, cursor, length);
      if (kw < 0) break;
      cursor = kw + _streamKw.length;
      // Must be the keyword "stream", not the tail of "endstream" or a name.
      if (kw >= 3 && _matchesAt('end'.codeUnits, kw - 3)) continue;
      final info = _parseStream(kw);
      if (info == null) continue;
      count++;
      if (count > limits.maxStreams) {
        return _result(PrescanVerdict.unsafe, count, 0, 0, issue: PrescanIssue.tooManyStreams);
      }
      cursor = math.max(cursor, info.dataEnd);
      final issue = _staticIssue(info);
      if (issue != null) {
        return _result(PrescanVerdict.unsafe, count, 0, 0,
            issue: issue, detail: 'stream@${info.dataStart} filters=${info.filters}');
      }
      if (info.flateLayers > 0 && info.worstCase > _capFor(info)) streams.add(info);
      if (_overBudget) return _result(PrescanVerdict.incomplete, count, 0, 0, detail: 'budget during index');
    }

    // Pass 2: inflate risky streams, most dangerous first.
    streams.sort((a, b) => b.worstCase.compareTo(a.worstCase));
    var inflated = 0;
    var bytes = 0;
    for (final s in streams) {
      if (_overBudget) {
        return _result(PrescanVerdict.incomplete, count, inflated, bytes, detail: 'budget during inflate');
      }
      final cap = _capFor(s);
      final (n, exceeded) = _countInflated(s, cap);
      inflated++;
      bytes += n;
      if (exceeded) {
        return _result(PrescanVerdict.unsafe, count, inflated, bytes,
            issue: PrescanIssue.decompressionBomb,
            detail: 'stream@${s.dataStart} raw=${s.rawLength} decoded>$cap filters=${s.filters}');
      }
    }
    return _result(PrescanVerdict.ok, count, inflated, bytes);
  }

  int _capFor(_StreamInfo s) {
    final img = s.imageBytes;
    if (img == null) return limits.maxStreamBytes;
    // PNG predictors add one byte per row; allow generous slack.
    return math.min(limits.maxImageBytes, math.max(limits.maxStreamBytes, img + img ~/ 8 + (1 << 20)));
  }

  PrescanIssue? _staticIssue(_StreamInfo s) {
    if (s.imageBytes != null && s.imageBytes! > limits.maxImageBytes) return PrescanIssue.oversizedImage;
    const amplifying = {'Flate', 'LZW', 'RL'};
    final amp = s.filters.where(amplifying.contains).length;
    final unverifiable = s.filters.any((f) => f == 'LZW' || f == 'RL');
    if (amp >= 2 && unverifiable) return PrescanIssue.unverifiableNestedCompression;
    return null;
  }

  /// Returns (decoded bytes counted, exceeded cap).
  (int, bool) _countInflated(_StreamInfo s, int cap) {
    // Closed through the decoder chain (sink.close()); a no-op sink anyway.
    // ignore: close_sinks
    final counter = _CountingSink(cap);
    // Chain decoders: raw -> Flate#1 -> Flate#2 -> ... -> counter.
    Sink<List<int>> sink = counter;
    for (var i = 0; i < s.flateLayers; i++) {
      sink = ZLibDecoder().startChunkedConversion(sink);
    }
    final buf = Uint8List(64 * 1024);
    var pos = s.dataStart;
    try {
      raf.setPositionSync(pos);
      while (pos < s.dataEnd) {
        final want = math.min(buf.length, s.dataEnd - pos);
        final n = raf.readIntoSync(buf, 0, want);
        if (n <= 0) break;
        sink.add(Uint8List.sublistView(buf, 0, n));
        pos += n;
        if (_overBudget) break;
      }
      sink.close();
    } on _CapExceeded {
      return (counter.count, true);
    } on FormatException {
      // Corrupt data: PDFium stops at the same point; count what we got.
    } on FileSystemException {
      // treat as end of data
    } catch (_) {
      // zlib errors surface as different types across platforms
    }
    return (counter.count, false);
  }

  // ---- parsing ------------------------------------------------------------

  _StreamInfo? _parseStream(int kw) {
    // Data starts after "stream" + CRLF or LF (tolerate CR alone).
    var dataStart = kw + _streamKw.length;
    final eol = _readBytes(dataStart, 2);
    if (eol.isNotEmpty && eol[0] == 0x0D) {
      dataStart += (eol.length > 1 && eol[1] == 0x0A) ? 2 : 1;
    } else if (eol.isNotEmpty && eol[0] == 0x0A) {
      dataStart += 1;
    } else if (eol.isNotEmpty && eol[0] != 0x20) {
      return null; // "streamfoo": not a stream keyword
    }

    final dict = _readDict(kw);
    if (dict == null) return null;
    final filters = _filters(dict);

    int? dataEnd;
    final len = _directInt(dict, 'Length');
    if (len != null && len >= 0 && dataStart + len <= length) {
      final tail = String.fromCharCodes(_readBytes(dataStart + len, 12));
      if (tail.trimLeft().startsWith('endstream')) dataEnd = dataStart + len;
    }
    if (dataEnd == null) {
      final end = _find(_endstreamKw, dataStart, length);
      dataEnd = end < 0 ? length : end;
    }

    int? imageBytes;
    if (RegExp(r'/Subtype\s*/Image\b').hasMatch(dict)) {
      final w = _directInt(dict, 'Width');
      final h = _directInt(dict, 'Height');
      if (w != null && h != null && w > 0 && h > 0) {
        final isMask = RegExp(r'/ImageMask\s+true').hasMatch(dict);
        final bpc = isMask ? 1 : (_directInt(dict, 'BitsPerComponent') ?? 8).clamp(1, 16);
        final comps = isMask ? 1 : _components(dict);
        final rowBytes = (w * comps * bpc + 7) ~/ 8;
        imageBytes = rowBytes * h; // int is 64-bit on all our platforms
      }
    }
    return _StreamInfo(dataStart, dataEnd, filters, imageBytes);
  }

  /// Text of the dictionary that ends just before the `stream` keyword.
  String? _readDict(int kw) {
    final start = math.max(0, kw - _dictWindow);
    final bytes = _readBytes(start, kw - start);
    var i = bytes.length - 1;
    while (i >= 0 && _isWhite(bytes[i])) {
      i--;
    }
    if (i < 1 || bytes[i] != 0x3E || bytes[i - 1] != 0x3E) return null; // ">>"
    var depth = 0;
    for (var j = i; j >= 1; j--) {
      if (bytes[j] == 0x3E && bytes[j - 1] == 0x3E) {
        depth++;
        j--;
      } else if (bytes[j] == 0x3C && bytes[j - 1] == 0x3C) {
        depth--;
        j--;
        if (depth == 0) return String.fromCharCodes(bytes, j, i + 1);
      }
    }
    return null;
  }

  static final _filterArray = RegExp(r'/Filter\s*\[([^\]]*)\]');
  static final _filterName = RegExp(r'/Filter\s*/([A-Za-z0-9#]+)');

  static List<String> _filters(String dict) {
    // Only the stream's own /Filter (DecodeParms can't hold one); first match wins.
    final arr = _filterArray.firstMatch(dict);
    final names = arr != null
        ? RegExp(r'/([A-Za-z0-9#]+)').allMatches(arr.group(1)!).map((m) => m.group(1)!).toList()
        : [if (_filterName.firstMatch(dict) case final m?) m.group(1)!];
    return names.map(_normFilter).toList();
  }

  static String _normFilter(String n) => switch (n.replaceAll('#20', ' ')) {
        'FlateDecode' || 'Fl' => 'Flate',
        'LZWDecode' || 'LZW' => 'LZW',
        'RunLengthDecode' || 'RL' => 'RL',
        'ASCIIHexDecode' || 'AHx' => 'AHx',
        'ASCII85Decode' || 'A85' => 'A85',
        'DCTDecode' || 'DCT' => 'DCT',
        'JPXDecode' => 'JPX',
        'JBIG2Decode' => 'JBIG2',
        'CCITTFaxDecode' || 'CCF' => 'CCF',
        'Crypt' => 'Crypt',
        _ => 'other',
      };

  static int? _directInt(String dict, String key) {
    // Direct integer only ("/Length 12 0 R" is an indirect reference -> null).
    final m = RegExp('/$key\\s+(\\d{1,15})(?!\\s+\\d+\\s+R)\\b').firstMatch(dict);
    if (m == null) return null;
    final after = dict.substring(m.end);
    if (RegExp(r'^\s+\d+\s+R\b').hasMatch(after)) return null;
    return int.tryParse(m.group(1)!);
  }

  static int _components(String dict) {
    if (RegExp(r'/ColorSpace\s*/(DeviceGray|CalGray|G)\b').hasMatch(dict)) return 1;
    if (RegExp(r'/ColorSpace\s*/(DeviceRGB|CalRGB|RGB|Lab)\b').hasMatch(dict)) return 3;
    if (RegExp(r'/ColorSpace\s*\[\s*/Indexed').hasMatch(dict)) return 1;
    return 4; // CMYK, ICC or unknown: assume the largest common case
  }

  static bool _isWhite(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00;

  // Read-through window cache: indexing reads mostly forwards with short
  // look-backs for dictionaries, so one 1 MiB window keeps I/O sequential.
  Uint8List _cache = Uint8List(0);
  int _cacheStart = 0;

  Uint8List _readBytes(int start, int n) {
    if (start >= length || n <= 0) return Uint8List(0);
    n = math.min(n, length - start);
    if (start < _cacheStart || start + n > _cacheStart + _cache.length) {
      final winStart = math.max(0, start - _dictWindow);
      final winLen = math.min(length - winStart, math.max(_chunk, n + (start - winStart)));
      raf.setPositionSync(winStart);
      _cache = raf.readSync(winLen);
      _cacheStart = winStart;
      if (start + n > _cacheStart + _cache.length) n = _cacheStart + _cache.length - start;
      if (n <= 0) return Uint8List(0);
    }
    return Uint8List.sublistView(_cache, start - _cacheStart, start - _cacheStart + n);
  }

  bool _matchesAt(List<int> pat, int at) {
    final b = _readBytes(at, pat.length);
    if (b.length < pat.length) return false;
    for (var i = 0; i < pat.length; i++) {
      if (b[i] != pat[i]) return false;
    }
    return true;
  }

  /// First offset >= [from] where [pat] occurs, scanning in chunks; -1 if none.
  int _find(List<int> pat, int from, int to) {
    var pos = from;
    final first = pat[0];
    while (pos < to) {
      final n = math.min(_chunk + pat.length, to - pos);
      final b = _readBytes(pos, n);
      if (b.isEmpty) return -1;
      final last = b.length - pat.length;
      outer:
      for (var i = 0; i <= last; i++) {
        if (b[i] != first) continue;
        for (var j = 1; j < pat.length; j++) {
          if (b[i + j] != pat[j]) continue outer;
        }
        return pos + i;
      }
      if (b.length < n) return -1;
      pos += _chunk;
    }
    return -1;
  }
}
