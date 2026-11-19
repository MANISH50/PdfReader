import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

const _w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';

Uint8List tinyPng() => img.encodePng(img.Image(width: 4, height: 3));

/// A small but representative DOCX: heading, bold/italic runs, a bulleted and
/// a numbered list, a table, an external hyperlink, an image and a page break.
String sampleDocumentXml({String extraBody = ''}) => '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document $_w><w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Quarterly report</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Plain and </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r><w:r><w:rPr><w:i/><w:u w:val="single"/></w:rPr><w:t xml:space="preserve"> italic</w:t></w:r><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t xml:space="preserve"> notbold</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>First bullet</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Step one</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Step two</w:t></w:r></w:p>
<w:tbl><w:tblPr/><w:tr><w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Value</w:t></w:r></w:p></w:tc></w:tr>
<w:tr><w:tc><w:p><w:r><w:t>Alpha</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>42</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:t xml:space="preserve">Visit </w:t></w:r><w:hyperlink r:id="rIdLink"><w:r><w:t>our site</w:t></w:r></w:hyperlink></w:p>
<w:p><w:r><w:drawing><wp:inline><wp:docPr id="1" name="Picture 1" descr="Chart"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rIdImg"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
<w:p><w:r><w:t>After the break</w:t></w:r></w:p>
$extraBody
<w:sectPr/></w:body></w:document>''';

const sampleStylesXml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
</w:styles>''';

const sampleNumberingXml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:abstractNum w:abstractNumId="10"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
<w:abstractNum w:abstractNumId="20"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>
<w:num w:numId="2"><w:abstractNumId w:val="20"/></w:num>
</w:numbering>''';

const sampleRelsXml = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rIdLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/page" TargetMode="External"/>
<Relationship Id="rIdImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
</Relationships>''';

Uint8List buildZip(Map<String, List<int>> files) {
  final a = Archive();
  for (final e in files.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

Uint8List sampleDocx({String? documentXml, Map<String, List<int>> extra = const {}}) => buildZip({
      '[Content_Types].xml': utf8.encode('<Types/>'),
      'word/document.xml': utf8.encode(documentXml ?? sampleDocumentXml()),
      'word/styles.xml': utf8.encode(sampleStylesXml),
      'word/numbering.xml': utf8.encode(sampleNumberingXml),
      'word/_rels/document.xml.rels': utf8.encode(sampleRelsXml),
      'word/media/image1.png': tinyPng(),
      ...extra,
    });

/// Rewrites the declared uncompressed size of [name] in both the local and
/// central headers (a lying zip bomb).
Uint8List lieAboutSize(Uint8List zip, String name, int declared) {
  final out = Uint8List.fromList(zip);
  final bd = ByteData.sublistView(out);
  final nameBytes = utf8.encode(name);
  bool nameAt(int off) {
    if (off + nameBytes.length > out.length) return false;
    for (var i = 0; i < nameBytes.length; i++) {
      if (out[off + i] != nameBytes[i]) return false;
    }
    return true;
  }

  for (var i = 0; i + 46 < out.length; i++) {
    final sig = bd.getUint32(i, Endian.little);
    if (sig == 0x04034b50 && nameAt(i + 30)) bd.setUint32(i + 22, declared, Endian.little);
    if (sig == 0x02014b50 && nameAt(i + 46)) bd.setUint32(i + 24, declared, Endian.little);
  }
  return out;
}
