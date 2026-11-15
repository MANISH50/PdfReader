import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Writes a large PDF on the device/host without Python: [pages] pages, each
/// with its own copy of a random-noise JPEG, until the file is at least
/// [minBytes]. Equivalent to `make_corpus.py --huge` (1,200 pages, 100+ MB);
/// used by integration tests where host files cannot be pushed into the app
/// sandbox. Streams to disk, so memory stays small.
Future<File> writeHugePdf(
  String path, {
  int pages = 1200,
  int minBytes = 100 * 1024 * 1024,
  int seed = 20261115,
  int distinctImages = 16,
}) async {
  final rnd = Random(seed);
  const side = 340;
  final jpegs = <Uint8List>[
    for (var i = 0; i < distinctImages; i++)
      img.encodeJpg(
        img.Image.fromBytes(
          width: side,
          height: side,
          numChannels: 1,
          bytes: Uint8List.fromList(List.generate(side * side, (_) => rnd.nextInt(256))).buffer,
        ),
        quality: 92,
      ),
  ];
  final perPage = jpegs.first.length;
  final n = max(pages, (minBytes / perPage).ceil());

  final out = File(path).openSync(mode: FileMode.write);
  var pos = 0;
  final offsets = <int, int>{};
  void raw(List<int> b) {
    out.writeFromSync(b);
    pos += b.length;
  }

  void obj(int num, String body, [List<int>? stream]) {
    offsets[num] = pos;
    raw(latin1.encode('$num 0 obj\n$body\n'));
    if (stream != null) {
      raw(latin1.encode('stream\n'));
      raw(stream);
      raw(latin1.encode('\nendstream\n'));
    }
    raw(latin1.encode('endobj\n'));
  }

  raw(latin1.encode('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n'));
  // 1 catalog, 2 pages, 3 font; page i uses objects 4+3i (page), 5+3i (content), 6+3i (image)
  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  final kids = StringBuffer();
  for (var i = 0; i < n; i++) {
    kids.write('${4 + 3 * i} 0 R ');
  }
  obj(2, '<< /Type /Pages /Count $n /Kids [$kids] >>');
  obj(3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  for (var i = 0; i < n; i++) {
    final p = 4 + 3 * i;
    final content = latin1.encode('q 500 0 0 500 56 250 cm /Im0 Do Q BT /F1 24 Tf 56 780 Td (Huge page ${i + 1}) Tj ET');
    final jpg = jpegs[i % jpegs.length];
    obj(p, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 842] '
        '/Resources << /Font << /F1 3 0 R >> /XObject << /Im0 ${p + 2} 0 R >> >> /Contents ${p + 1} 0 R >>');
    obj(p + 1, '<< /Length ${content.length} >>', content);
    obj(p + 2, '<< /Type /XObject /Subtype /Image /Width $side /Height $side /ColorSpace /DeviceGray '
        '/BitsPerComponent 8 /Filter /DCTDecode /Length ${jpg.length} >>', jpg);
  }
  final size = 4 + 3 * n;
  final xref = pos;
  final sb = StringBuffer('xref\n0 $size\n0000000000 65535 f \n');
  for (var i = 1; i < size; i++) {
    sb.write('${offsets[i]!.toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<< /Size $size /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  raw(latin1.encode(sb.toString()));
  out.closeSync();
  return File(path);
}
