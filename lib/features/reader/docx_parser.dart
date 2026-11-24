import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xml/xml_events.dart';

import '../../core/documents/document_kind.dart';
import '../../core/security/limits.dart';
import 'reader_model.dart';
import 'safe_zip.dart';

export 'safe_zip.dart' show DocxLimits;

/// Shown above every DOCX in the reader.
const docxNotice = 'Showing text and basic formatting; complex layouts may look different.';

/// Parses a DOCX file's bytes into reader blocks.
///
/// Security: the ZIP's central directory is validated first (entry count,
/// no absolute or `..` names, no encryption, declared sizes within caps);
/// every part is then inflated through a counting sink that aborts at the
/// cap (zip bombs lie about sizes). XML is pull-parsed: DOCTYPEs are skipped
/// and no entity from a DTD is ever expanded or fetched. Macros
/// (vbaProject.bin) are never read.
ReaderDocument parseDocx(Uint8List bytes, {DocxLimits limits = const DocxLimits(), ParseBudget? budget}) {
  try {
    final zip = SafeZip(bytes, limits, budget);
    final docXml = zip.readText('word/document.xml', limits.maxXmlBytes);
    if (docXml == null) throw const ReaderOpenException(ReaderFailure.damaged);
    final styles = _Styles.parse(zip.readText('word/styles.xml', limits.maxXmlBytes), budget);
    final numbering = _Numbering.parse(zip.readText('word/numbering.xml', limits.maxXmlBytes), budget);
    final rels = parseRels(zip.readText('word/_rels/document.xml.rels', limits.maxXmlBytes));
    final blocks = _DocxBody(zip, styles, numbering, rels, limits, budget).parse(docXml);
    return ReaderDocument(kind: DocumentKind.docx, blocks: blocks, notice: docxNotice);
  } on ReaderOpenException {
    rethrow;
  } on ZipBomb {
    throw const ReaderOpenException(ReaderFailure.unsafe);
  } catch (_) {
    throw const ReaderOpenException(ReaderFailure.damaged);
  }
}

class _Style {
  String? name, basedOn;
  int? outline;
  String? numId;
  int? ilvl;
}

class _Styles {
  _Styles(this.styles);
  final Map<String, _Style> styles;

  static _Styles parse(String? xml, ParseBudget? budget) {
    final m = <String, _Style>{};
    if (xml == null) return _Styles(m);
    _Style? cur;
    var n = 0;
    for (final e in xmlEvents(xml)) {
      if (++n % 4096 == 0) budget?.check();
      if (e is XmlStartElementEvent) {
        switch (xmlLocal(e.name)) {
          case 'style':
            final id = xmlAttr(e, 'styleId');
            cur = (id != null && (xmlAttr(e, 'type') ?? 'paragraph') == 'paragraph') ? (m[id] = _Style()) : null;
          case 'name':
            cur?.name = xmlAttr(e, 'val');
          case 'basedOn':
            cur?.basedOn = xmlAttr(e, 'val');
          case 'outlineLvl':
            cur?.outline = int.tryParse(xmlAttr(e, 'val') ?? '');
          case 'numId':
            cur?.numId = xmlAttr(e, 'val');
          case 'ilvl':
            cur?.ilvl = int.tryParse(xmlAttr(e, 'val') ?? '');
        }
      } else if (e is XmlEndElementEvent && xmlLocal(e.name) == 'style') {
        cur = null;
      }
    }
    return _Styles(m);
  }

  /// Heading level 1-6 for paragraph style [id], or 0.
  int headingLevel(String? id) {
    var s = id;
    for (var depth = 0; s != null && depth < 10; depth++) {
      final st = styles[s];
      final name = (st?.name ?? s).toLowerCase().replaceAll(' ', '');
      final m = RegExp(r'^heading([1-9])$').firstMatch(name);
      if (m != null) return int.parse(m.group(1)!).clamp(1, 6);
      if (name == 'title') return 1;
      if (name == 'subtitle') return 2;
      final o = st?.outline;
      if (o != null && o >= 0 && o < 9) return (o + 1).clamp(1, 6);
      s = st?.basedOn;
    }
    return 0;
  }

  ({String? numId, int? ilvl}) numbering(String? id) {
    var s = id;
    for (var depth = 0; s != null && depth < 10; depth++) {
      final st = styles[s];
      if (st?.numId != null) return (numId: st!.numId, ilvl: st.ilvl);
      s = st?.basedOn;
    }
    return (numId: null, ilvl: null);
  }
}

class _Numbering {
  _Numbering(this.numToAbstract, this.formats);
  final Map<String, String> numToAbstract;

  /// abstractNumId → ilvl → (format, start).
  final Map<String, Map<int, ({String fmt, int start})>> formats;
  final _counters = <String, List<int>>{};

  static _Numbering parse(String? xml, ParseBudget? budget) {
    final numTo = <String, String>{};
    final fmts = <String, Map<int, ({String fmt, int start})>>{};
    if (xml == null) return _Numbering(numTo, fmts);
    String? abs, num;
    int? lvl;
    var fmt = 'decimal';
    var start = 1;
    var n = 0;
    for (final e in xmlEvents(xml)) {
      if (++n % 4096 == 0) budget?.check();
      if (e is XmlStartElementEvent) {
        switch (xmlLocal(e.name)) {
          case 'abstractNum':
            abs = xmlAttr(e, 'abstractNumId');
          case 'lvl':
            lvl = int.tryParse(xmlAttr(e, 'ilvl') ?? '');
            fmt = 'decimal';
            start = 1;
          case 'numFmt':
            fmt = xmlAttr(e, 'val') ?? 'decimal';
          case 'start':
            start = int.tryParse(xmlAttr(e, 'val') ?? '') ?? 1;
          case 'num':
            num = xmlAttr(e, 'numId');
          case 'abstractNumId':
            final v = xmlAttr(e, 'val');
            if (num != null && v != null) numTo[num] = v;
        }
      } else if (e is XmlEndElementEvent) {
        switch (xmlLocal(e.name)) {
          case 'lvl':
            if (abs != null && lvl != null) (fmts[abs] ??= {})[lvl] = (fmt: fmt, start: start);
            lvl = null;
          case 'abstractNum':
            abs = null;
          case 'num':
            num = null;
        }
      }
    }
    return _Numbering(numTo, fmts);
  }

  /// Marker for the next item of list [numId] at level [ilvl].
  String marker(String numId, int ilvl) {
    final lvl = ilvl.clamp(0, 8);
    final f = formats[numToAbstract[numId]]?[lvl] ?? (fmt: lvl.isEven ? 'decimal' : 'bullet', start: 1);
    final c = _counters[numId] ??= List.filled(9, 0);
    c[lvl]++;
    for (var i = lvl + 1; i < 9; i++) {
      c[i] = 0;
    }
    final n = f.start + c[lvl] - 1;
    return switch (f.fmt) {
      'bullet' => const ['•', '◦', '▪'][lvl % 3],
      'none' => '',
      'lowerLetter' => '${_letters(n)}.',
      'upperLetter' => '${_letters(n).toUpperCase()}.',
      'lowerRoman' => '${_roman(n)}.',
      'upperRoman' => '${_roman(n).toUpperCase()}.',
      _ => '$n.',
    };
  }

  static String _letters(int n) {
    if (n < 1) return 'a';
    final ch = String.fromCharCode(0x61 + (n - 1) % 26);
    return ch * ((n - 1) ~/ 26 + 1);
  }

  static String _roman(int n) {
    if (n < 1 || n > 3999) return '$n';
    const vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const syms = ['m', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i'];
    final b = StringBuffer();
    for (var i = 0; i < vals.length; i++) {
      while (n >= vals[i]) {
        b.write(syms[i]);
        n -= vals[i];
      }
    }
    return b.toString();
  }
}

/// Elements whose whole subtree is ignored.
const _skipped = {
  'Fallback',
  'instrText',
  'delText',
  'footnoteReference',
  'endnoteReference',
  'commentReference',
  'txbxContent',
  'sectPr',
  'tblPr',
  'tblGrid',
  'trPr',
  'tcPr',
  'object',
  'chart',
};

class _DocxBody {
  _DocxBody(this.zip, this.styles, this.numbering, this.rels, this.limits, this.budget);
  final SafeZip zip;
  final _Styles styles;
  final _Numbering numbering;
  final Map<String, ({String target, bool external})> rels;
  final DocxLimits limits;
  final ParseBudget? budget;

  final out = <RBlock>[];
  final _images = <String, ImageBlock>{};

  // Paragraph state.
  var _spans = <RSpan>[];
  String? _pStyle, _numId;
  int? _ilvl, _outline;
  bool _inPPr = false, _inRPr = false, _inRun = false, _inT = false, _pageBreakBefore = false;
  bool _b = false, _i = false, _u = false, _s = false, _hidden = false;
  final _links = <String?>[];

  // Drawing state.
  int _drawing = 0;
  String? _imageRel, _imageAlt;

  // Tables: only the outermost table becomes a grid; nested tables flatten
  // into the outer cell.
  int _tbl = 0;
  List<List<List<List<RSpan>>>>? _rows;
  List<List<List<RSpan>>>? _row;
  List<List<RSpan>>? _cell;

  List<RBlock> parse(String xml) {
    var skip = 0;
    var n = 0;
    for (final e in xmlEvents(xml)) {
      if (++n % 4096 == 0) budget?.check();
      if (e is XmlStartElementEvent) {
        final name = xmlLocal(e.name);
        if (skip > 0) {
          if (!e.isSelfClosing) skip++;
          continue;
        }
        if (_skipped.contains(name) || (name == 'rPr' && _inPPr)) {
          if (!e.isSelfClosing) skip = 1;
          continue;
        }
        _start(name, e);
        if (e.isSelfClosing) _end(name);
      } else if (e is XmlEndElementEvent) {
        if (skip > 0) {
          skip--;
          continue;
        }
        _end(xmlLocal(e.name));
      } else if ((e is XmlTextEvent || e is XmlCDATAEvent) && skip == 0 && _inT && !_hidden && _drawing == 0) {
        _text(e is XmlTextEvent ? e.value : (e as XmlCDATAEvent).value);
      }
    }
    if (_spans.isNotEmpty) _endParagraph();
    return out;
  }

  void _text(String t) {
    if (t.isEmpty) return;
    _spans.add(RSpan(t, bold: _b, italic: _i, underline: _u, strike: _s, link: _links.lastOrNull));
  }

  void _start(String name, XmlStartElementEvent e) {
    if (_drawing > 0) {
      switch (name) {
        case 'blip':
          _imageRel ??= xmlAttr(e, 'embed');
        case 'imagedata':
          _imageRel ??= xmlAttr(e, 'id');
        case 'docPr':
          _imageAlt ??= xmlAttr(e, 'descr') ?? xmlAttr(e, 'title');
      }
      if (name == 'drawing' || name == 'pict') _drawing++;
      return;
    }
    switch (name) {
      case 'p':
        _spans = [];
        _pStyle = _numId = null;
        _ilvl = _outline = null;
        _pageBreakBefore = false;
      case 'pPr':
        _inPPr = true;
      case 'pStyle' when _inPPr:
        _pStyle = xmlAttr(e, 'val');
      case 'numId' when _inPPr:
        _numId = xmlAttr(e, 'val');
      case 'ilvl' when _inPPr:
        _ilvl = int.tryParse(xmlAttr(e, 'val') ?? '');
      case 'outlineLvl' when _inPPr:
        _outline = int.tryParse(xmlAttr(e, 'val') ?? '');
      case 'pageBreakBefore' when _inPPr:
        _pageBreakBefore = xmlOnOff(e);
      case 'r':
        _inRun = true;
        _b = _i = _u = _s = _hidden = false;
      case 'rPr' when _inRun:
        _inRPr = true;
      case 'b' when _inRPr:
        _b = xmlOnOff(e);
      case 'i' when _inRPr:
        _i = xmlOnOff(e);
      case 'u' when _inRPr:
        _u = xmlOnOff(e);
      case ('strike' || 'dstrike') when _inRPr:
        _s = xmlOnOff(e);
      case 'vanish' when _inRPr:
        _hidden = xmlOnOff(e);
      case 't' when _inRun:
        _inT = true;
      case 'tab' when _inRun && !_inPPr:
        _text('\t');
      case ('cr') when _inRun:
        _text('\n');
      case 'noBreakHyphen' when _inRun:
        _text('-');
      case 'br' when _inRun:
        if (xmlAttr(e, 'type') == 'page') {
          _pageBreak();
        } else {
          _text('\n');
        }
      case 'hyperlink':
        final id = xmlAttr(e, 'id');
        final rel = id == null ? null : rels[id];
        _links.add(rel != null && rel.external ? rel.target : null);
      case 'drawing' || 'pict':
        _drawing = 1;
        _imageRel = _imageAlt = null;
      case 'tbl':
        _flushParagraphSpansBeforeTable();
        _tbl++;
        if (_tbl == 1) _rows = [];
      case 'tr' when _tbl == 1:
        _row = [];
      case 'tc' when _tbl == 1:
        _cell = [];
    }
  }

  void _end(String name) {
    if (_drawing > 0) {
      if (name == 'drawing' || name == 'pict') {
        _drawing--;
        if (_drawing == 0) _image();
      }
      return;
    }
    switch (name) {
      case 'p':
        _endParagraph();
      case 'pPr':
        _inPPr = false;
      case 'rPr':
        _inRPr = false;
      case 'r':
        _inRun = false;
        _inRPr = false;
      case 't':
        _inT = false;
      case 'hyperlink':
        if (_links.isNotEmpty) _links.removeLast();
      case 'tc' when _tbl == 1:
        if (_cell != null) _row?.add(_cell!);
        _cell = null;
      case 'tr' when _tbl == 1:
        if (_row != null && _row!.isNotEmpty) _rows?.add(_row!);
        _row = null;
      case 'tbl':
        _tbl--;
        if (_tbl == 0) {
          final rows = _rows;
          _rows = null;
          if (rows != null && rows.isNotEmpty) out.add(TableBlock(rows));
        }
    }
  }

  void _flushParagraphSpansBeforeTable() {
    // A table can't be inside a paragraph, but be defensive with odd files.
    if (_spans.isNotEmpty && _tbl == 0) _endParagraph();
  }

  void _pageBreak() {
    if (_tbl > 0) return;
    if (_spans.isNotEmpty) {
      _emitParagraph(_spans);
      _spans = [];
    }
    out.add(const PageBreakBlock());
  }

  void _endParagraph() {
    if (_pageBreakBefore && _tbl == 0) out.add(const PageBreakBlock());
    _pageBreakBefore = false;
    _emitParagraph(_spans);
    _spans = [];
  }

  void _emitParagraph(List<RSpan> spans) {
    var numId = _numId, ilvl = _ilvl;
    if (numId == null) {
      final s = styles.numbering(_pStyle);
      numId = s.numId;
      ilvl ??= s.ilvl;
    }
    final marker = (numId != null && numId != '0') ? numbering.marker(numId, ilvl ?? 0) : null;
    if (_tbl > 0) {
      if (spans.isEmpty && marker == null) {
        _cell?.add(const []);
        return;
      }
      _cell?.add([if (marker != null && marker.isNotEmpty) RSpan('$marker '), ...spans]);
      return;
    }
    var level = styles.headingLevel(_pStyle);
    final o = _outline;
    if (level == 0 && o != null && o >= 0 && o < 6) level = o + 1;
    if (spans.isEmpty && marker == null) {
      // Keep single empty paragraphs as spacing, collapse runs of them.
      if (out.isNotEmpty && out.last is TextBlock && (out.last as TextBlock).spans.isEmpty) return;
      out.add(const TextBlock([]));
      return;
    }
    out.add(
      TextBlock(
        spans,
        headingLevel: marker == null ? level : 0,
        marker: (marker == null || marker.isEmpty) ? null : marker,
        indent: marker == null ? 0 : (ilvl ?? 0).clamp(0, 8),
      ),
    );
  }

  void _image() {
    final alt = (_imageAlt ?? '').trim();
    final rel = _imageRel == null ? null : rels[_imageRel];
    _imageRel = null;
    _imageAlt = null;
    if (_tbl > 0) {
      _spans.add(RSpan.image(alt));
      return;
    }
    if (_spans.isNotEmpty) {
      _emitParagraph(_spans);
      _spans = [];
    }
    if (rel == null || rel.external) {
      // Linked (external) images are never fetched.
      out.add(ImageBlock(alt: alt));
      return;
    }
    final path = p.posix.normalize(p.posix.join('word', rel.target));
    out.add(_images[path] ??= _loadImage(path, alt));
  }

  ImageBlock _loadImage(String path, String alt) {
    final ext = p.posix.extension(path).toLowerCase();
    if (!const {'.png', '.jpg', '.jpeg', '.gif'}.contains(ext)) return ImageBlock(alt: alt);
    final Uint8List? bytes;
    try {
      bytes = zip.read(path, limits.maxImageBytes);
    } on ZipBomb {
      return ImageBlock(alt: alt);
    }
    if (bytes == null) return ImageBlock(alt: alt);
    final size = imageSize(bytes);
    if (size == null || size.w <= 0 || size.h <= 0 || size.w * size.h > limits.maxImagePixels) {
      return ImageBlock(alt: alt);
    }
    return ImageBlock(bytes: bytes, alt: alt, width: size.w, height: size.h);
  }
}

/// Pixel size from a PNG, GIF or JPEG header; null if unrecognised.
({int w, int h})? imageSize(Uint8List b) {
  final d = ByteData.sublistView(b);
  if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return (w: d.getUint32(16), h: d.getUint32(20));
  }
  if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return (w: d.getUint16(6, Endian.little), h: d.getUint16(8, Endian.little));
  }
  if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = d.getUint16(i + 2);
      final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (isSof) return (w: d.getUint16(i + 7), h: d.getUint16(i + 5));
      if (len < 2) return null;
      i += 2 + len;
    }
  }
  return null;
}

/// Reads and parses the DOCX at [path] (file must be ≤ the DOCX cap).
ReaderDocument parseDocxFile(String path, {ParseBudget? budget}) {
  final f = io.File(path);
  if (f.lengthSync() > SecurityLimits.maxDocxFileBytes) throw const ReaderOpenException(ReaderFailure.tooLarge);
  return parseDocx(f.readAsBytesSync(), budget: budget);
}
