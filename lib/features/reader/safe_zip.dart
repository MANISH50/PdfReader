import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

import '../../core/documents/document_kind.dart';
import '../../core/security/limits.dart';
import 'reader_model.dart';

/// Hardened ZIP + XML reading shared by the DOCX and XLSX parsers.

/// Caps for reading an untrusted OOXML file (a ZIP). Defaults: [SecurityLimits].
class DocxLimits {
  const DocxLimits({
    this.maxEntries = SecurityLimits.maxDocxEntries,
    this.maxXmlBytes = SecurityLimits.maxDocxXmlBytes,
    this.maxImageBytes = SecurityLimits.maxDocxImageBytes,
    this.maxTotalBytes = SecurityLimits.maxDocxTotalBytes,
    this.maxImagePixels = SecurityLimits.maxRenderPixels,
  });
  final int maxEntries, maxXmlBytes, maxImageBytes, maxTotalBytes, maxImagePixels;
}

class ZipBomb implements Exception {
  const ZipBomb();
}

class SafeZip {
  SafeZip(this.bytes, this.limits, this.budget) {
    var n = 0;
    final headers = ZipDirectory().headers(InputMemoryStream(bytes), files: false);
    for (final h in headers) {
      if (++n > limits.maxEntries) throw const ReaderOpenException(ReaderFailure.unsafe);
      final name = h.filename;
      if (!_safeName(name)) throw const ReaderOpenException(ReaderFailure.unsafe);
      if (name.endsWith('/')) continue;
      // Duplicate names are a classic parser-confusion trick.
      if (entries.containsKey(name)) throw const ReaderOpenException(ReaderFailure.unsafe);
      entries[name] = h;
    }
    if (n == 0) throw const ReaderOpenException(ReaderFailure.damaged);
  }

  final Uint8List bytes;
  final DocxLimits limits;
  final ParseBudget? budget;
  final entries = <String, ZipFileHeader>{};
  int _total = 0;

  static bool _safeName(String name) {
    if (name.isEmpty || name.contains('\\') || name.contains('\u0000')) return false;
    if (name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name)) return false;
    return !name.split('/').any((s) => s == '..');
  }

  String? readText(String name, int cap) {
    final b = read(name, cap);
    if (b == null) return null;
    return decodeText(b, lenient: true);
  }

  /// Inflates [name] with a hard cap of [cap] bytes; null if missing.
  Uint8List? read(String name, int cap) {
    final h = entries[name];
    if (h == null) return null;
    if (h.generalPurposeBitFlag & 1 != 0) throw const ReaderOpenException(ReaderFailure.unsupported); // encrypted
    if (h.uncompressedSize > cap || _total + h.uncompressedSize > limits.maxTotalBytes) throw const ZipBomb();
    final off = h.localHeaderOffset;
    if (off < 0 || off + 30 > bytes.length) throw const ReaderOpenException(ReaderFailure.damaged);
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(off, Endian.little) != 0x04034b50) throw const ReaderOpenException(ReaderFailure.damaged);
    final start = off + 30 + bd.getUint16(off + 26, Endian.little) + bd.getUint16(off + 28, Endian.little);
    final end = start + h.compressedSize;
    if (end > bytes.length || h.compressedSize < 0) throw const ReaderOpenException(ReaderFailure.damaged);
    final raw = Uint8List.sublistView(bytes, start, end);
    final remaining = limits.maxTotalBytes - _total;
    final limit = cap < remaining ? cap : remaining;
    final Uint8List out;
    switch (h.compressionMethod) {
      case 0:
        if (raw.length > limit) throw const ZipBomb();
        out = raw;
      case 8:
        out = _inflateCapped(raw, limit);
      default:
        throw const ReaderOpenException(ReaderFailure.unsupported);
    }
    _total += out.length;
    return out;
  }

  Uint8List _inflateCapped(Uint8List raw, int limit) {
    final sink = _CappedSink(limit);
    final conv = io.ZLibDecoder(raw: true).startChunkedConversion(sink);
    const chunk = 64 * 1024;
    for (var i = 0; i < raw.length; i += chunk) {
      budget?.check();
      conv.add(Uint8List.sublistView(raw, i, i + chunk > raw.length ? raw.length : i + chunk));
    }
    conv.close();
    return sink.builder.takeBytes();
  }
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.limit);
  final int limit;
  final builder = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (builder.length + data.length > limit) throw const ZipBomb();
    builder.add(data);
  }

  @override
  void close() {}
}

// ---- XML helpers -----------------------------------------------------------

String xmlLocal(String qname) {
  final i = qname.indexOf(':');
  return i < 0 ? qname : qname.substring(i + 1);
}

String? xmlAttr(XmlStartElementEvent e, String local) {
  for (final a in e.attributes) {
    if (xmlLocal(a.name) == local) return a.value;
  }
  return null;
}

bool xmlOnOff(XmlStartElementEvent e) {
  final v = xmlAttr(e, 'val')?.toLowerCase();
  return v == null || !(v == '0' || v == 'false' || v == 'off' || v == 'none');
}

/// Pull-parses [xml]. DOCTYPE events are dropped (never interpreted).
Iterable<XmlEvent> xmlEvents(String xml) => parseEvents(xml).where((e) => e is! XmlDoctypeEvent);

Map<String, ({String target, bool external})> parseRels(String? xml) {
  final out = <String, ({String target, bool external})>{};
  if (xml == null) return out;
  for (final e in xmlEvents(xml)) {
    if (e is XmlStartElementEvent && xmlLocal(e.name) == 'Relationship') {
      final id = xmlAttr(e, 'Id'), target = xmlAttr(e, 'Target');
      if (id == null || target == null) continue;
      out[id] = (target: target, external: xmlAttr(e, 'TargetMode')?.toLowerCase() == 'external');
    }
  }
  return out;
}
