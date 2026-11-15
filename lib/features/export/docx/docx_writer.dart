import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';

import 'layout.dart';

/// A page image (e.g. a scanned page): a JPEG file on disk, streamed into
/// the package so images never pile up in memory.
class DocxImage {
  const DocxImage(this.path, {required this.pixelWidth, required this.pixelHeight});
  final String path;
  final int pixelWidth;
  final int pixelHeight;
}

/// Content of one exported page.
class DocxPage {
  DocxPage({required this.paragraphs, required this.widthPt, required this.heightPt, this.image});
  final List<TextParagraph> paragraphs;
  final double widthPt;
  final double heightPt;
  final DocxImage? image;
}

/// Hand-written minimal WordprocessingML (ECMA-376 transitional) package:
/// [Content_Types].xml, _rels/.rels, docProps/{core,app}.xml,
/// word/{document,styles,settings}.xml, word/_rels/document.xml.rels and
/// word/media/*.jpeg. Opens in Word, LibreOffice, Google Docs and Pages.
class DocxWriter {
  DocxWriter({required this.title, DateTime? created}) : created = (created ?? DateTime.now()).toUtc();

  final String title;
  final DateTime created;

  static const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  static const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const _marginTwips = 1080; // 0.75 inch

  /// Builds all package parts.
  DocxParts buildParts(List<DocxPage> pages, double bodySizePt) {
    final media = <String, String>{};
    final rels = <String>[];
    final body = StringBuffer();
    final first = pages.isEmpty ? null : pages.first;
    final pageW = _clampPt(first?.widthPt ?? 612), pageH = _clampPt(first?.heightPt ?? 792);
    final contentWEmu = ((pageW * 20 - 2 * _marginTwips) * 635).round(); // twips -> EMU
    final contentHEmu = ((pageH * 20 - 2 * _marginTwips) * 635).round();

    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (i > 0) body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      final image = page.image;
      if (image != null) {
        final id = media.length + 1;
        final name = 'image$id.jpeg';
        media[name] = image.path;
        final rId = 'rIdImg$id';
        rels.add('<Relationship Id="$rId" Type="$_r/image" Target="media/$name"/>');
        body.write(_imageParagraph(rId, id, image, contentWEmu, contentHEmu));
      }
      for (final p in page.paragraphs) {
        body.write(_paragraph(p, bodySizePt));
      }
      if (page.paragraphs.isEmpty && image == null) body.write('<w:p/>');
    }
    if (pages.isEmpty) body.write('<w:p/>');

    final orient = pageW > pageH ? ' w:orient="landscape"' : '';
    final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="$_w" xmlns:r="$_r" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<w:body>$body'
        '<w:sectPr><w:pgSz w:w="${(pageW * 20).round()}" w:h="${(pageH * 20).round()}"$orient/>'
        '<w:pgMar w:top="$_marginTwips" w:right="$_marginTwips" w:bottom="$_marginTwips" '
        'w:left="$_marginTwips" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>'
        '</w:body></w:document>';

    final docRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdStyles" Type="$_r/styles" Target="styles.xml"/>'
        '<Relationship Id="rIdSettings" Type="$_r/settings" Target="settings.xml"/>'
        '${rels.join()}</Relationships>';

    return DocxParts({
      '[Content_Types].xml': _utf8(_contentTypes(media.isNotEmpty)),
      '_rels/.rels': _utf8(_rootRels),
      'docProps/core.xml': _utf8(_core()),
      'docProps/app.xml': _utf8(_app),
      'word/document.xml': _utf8(document),
      'word/styles.xml': _utf8(_styles(bodySizePt)),
      'word/settings.xml': _utf8(_settings),
      'word/_rels/document.xml.rels': _utf8(docRels),
    }, {for (final e in media.entries) 'word/media/${e.key}': e.value});
  }

  /// Streams the package to [outPath]: XML parts deflated, JPEGs stored and
  /// copied from disk one at a time. Synchronous; call off the UI isolate.
  static void writeZip(DocxParts parts, String outPath) {
    final enc = ZipFileEncoder()..create(outPath);
    try {
      // [Content_Types].xml first, by convention.
      final names = parts.xml.keys.toList()..sort((a, b) => a.startsWith('[') ? -1 : (b.startsWith('[') ? 1 : 0));
      for (final name in names) {
        enc.addArchiveFile(ArchiveFile.bytes(name, parts.xml[name]!));
      }
      for (final e in parts.media.entries) {
        enc.addFileSync(File(e.value), e.key, ZipFileEncoder.store);
      }
    } finally {
      enc.closeSync();
    }
  }

  static double _clampPt(double v) => v.isFinite ? v.clamp(144, 1584) : 612; // 2in..22in (Word limit)

  String _paragraph(TextParagraph p, double bodySize) {
    final b = StringBuffer('<w:p>');
    final ppr = StringBuffer();
    final style = switch (p.kind) {
      BlockKind.heading1 => 'Heading1',
      BlockKind.heading2 => 'Heading2',
      BlockKind.heading3 => 'Heading3',
      BlockKind.paragraph => null,
    };
    if (style != null) ppr.write('<w:pStyle w:val="$style"/>');
    if (p.rtl) ppr.write('<w:bidi/>');
    if (ppr.isNotEmpty) b.write('<w:pPr>$ppr</w:pPr>');
    // Paragraphs notably smaller/larger than the body keep their size.
    final ownSize = p.kind == BlockKind.paragraph &&
            p.fontSize > 0 &&
            bodySize > 0 &&
            (p.fontSize - bodySize).abs() / bodySize > 0.1
        ? _halfPoints(p.fontSize)
        : null;
    for (final run in p.runs) {
      if (run.text.isEmpty) continue;
      final rpr = StringBuffer();
      if (run.bold && style == null) rpr.write('<w:b/><w:bCs/>');
      if (run.italic) rpr.write('<w:i/><w:iCs/>');
      if (ownSize != null) rpr.write('<w:sz w:val="$ownSize"/><w:szCs w:val="$ownSize"/>');
      if (p.rtl) rpr.write('<w:rtl/>');
      b.write('<w:r>');
      if (rpr.isNotEmpty) b.write('<w:rPr>$rpr</w:rPr>');
      _writeText(b, run.text);
      b.write('</w:r>');
    }
    b.write('</w:p>');
    return b.toString();
  }

  static void _writeText(StringBuffer b, String text) {
    final parts = text.split('\t');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) b.write('<w:tab/>');
      if (parts[i].isNotEmpty) b.write('<w:t xml:space="preserve">${xmlEscape(parts[i])}</w:t>');
    }
  }

  String _imageParagraph(String rId, int id, DocxImage img, int maxWEmu, int maxHEmu) {
    final aspect = img.pixelHeight / math.max(1, img.pixelWidth);
    var cx = maxWEmu;
    var cy = (cx * aspect).round();
    if (cy > maxHEmu) {
      cy = maxHEmu;
      cx = (cy / aspect).round();
    }
    return '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$id" name="Page image $id"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="$id" name="image$id.jpeg"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$rId"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';
  }

  static int _halfPoints(double pt) => (pt * 2).round().clamp(8, 400);

  String _contentTypes(bool hasImages) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '${hasImages ? '<Default Extension="jpeg" ContentType="image/jpeg"/>' : ''}'
      '<Override PartName="/word/document.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '<Override PartName="/word/settings.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '<Override PartName="/docProps/app.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
      '</Types>';

  static const _rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="word/document.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
      'Target="docProps/core.xml"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" '
      'Target="docProps/app.xml"/>'
      '</Relationships>';

  String _core() {
    final ts = '${created.toIso8601String().split('.').first}Z';
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${xmlEscape(title)}</dc:title>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">$ts</dcterms:created>'
        '<dcterms:modified xsi:type="dcterms:W3CDTF">$ts</dcterms:modified>'
        '</cp:coreProperties>';
  }

  static const _app = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>PdfReader</Application></Properties>';

  static const _settings = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:settings xmlns:w="$_w"><w:defaultTabStop w:val="720"/>'
      '<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" '
      'w:val="15"/></w:compat></w:settings>';

  String _styles(double bodySizePt) {
    final body = bodySizePt > 0 ? _halfPoints(bodySizePt.clamp(7, 16)) : 22;
    String heading(int level, int size) => '<w:style w:type="paragraph" w:styleId="Heading$level">'
        '<w:name w:val="heading $level"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
        '<w:pPr><w:keepNext/><w:spacing w:before="${level == 1 ? 360 : 240}" w:after="120"/>'
        '<w:outlineLvl w:val="${level - 1}"/></w:pPr>'
        '<w:rPr><w:b/><w:bCs/><w:sz w:val="$size"/><w:szCs w:val="$size"/></w:rPr></w:style>';
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:styles xmlns:w="$_w">'
        '<w:docDefaults><w:rPrDefault><w:rPr>'
        '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Arial"/>'
        '<w:sz w:val="$body"/><w:szCs w:val="$body"/><w:lang w:val="en-US" w:bidi="ar-SA"/>'
        '</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="264" w:lineRule="auto"/>'
        '</w:pPr></w:pPrDefault></w:docDefaults>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
        '${heading(1, math.max(body + 12, 32))}${heading(2, math.max(body + 6, 26))}${heading(3, math.max(body + 2, 24))}'
        '</w:styles>';
  }

  static List<int> _utf8(String s) => utf8.encode(s);
}

/// Package parts: XML (entry name -> bytes) and media (entry name -> file).
class DocxParts {
  const DocxParts(this.xml, this.media);
  final Map<String, List<int>> xml;
  final Map<String, String> media;
}

/// Escapes text for XML and drops characters XML 1.0 forbids (controls other
/// than tab/newline, lone surrogates, U+FFFE/U+FFFF).
String xmlEscape(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 < s.length) {
        final d = s.codeUnitAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          b.writeCharCode(c);
          b.writeCharCode(d);
          i++;
        }
      }
      continue;
    }
    if (c >= 0xDC00 && c <= 0xDFFF) continue;
    if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) continue;
    if (c == 0xFFFE || c == 0xFFFF) continue;
    // Bidi embedding/override/isolate controls can disguise text.
    if ((c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069)) continue;
    switch (c) {
      case 0x26:
        b.write('&amp;');
      case 0x3C:
        b.write('&lt;');
      case 0x3E:
        b.write('&gt;');
      case 0x22:
        b.write('&quot;');
      default:
        b.writeCharCode(c);
    }
  }
  return b.toString();
}
