import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// [count] A4 pages, each containing "Page N".
Future<Uint8List> makePdf(int count, {String prefix = 'Page'}) async {
  final d = pw.Document();
  for (var i = 1; i <= count; i++) {
    d.addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.Text('$prefix $i')));
  }
  return d.save();
}

/// One page with a text field, a checkbox and a combo box.
Future<Uint8List> makeFormPdf() async {
  final d = pw.Document();
  d.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    build: (_) => pw.Column(children: [
      pw.TextField(name: 'fullName', width: 200, height: 20),
      pw.SizedBox(height: 20),
      pw.Checkbox(name: 'agree', value: false, width: 16, height: 16),
      pw.SizedBox(height: 20),
      pw.ChoiceField(name: 'color', items: const ['Red', 'Green', 'Blue'], value: 'Red', width: 120, height: 20),
    ]),
  ));
  return d.save();
}
