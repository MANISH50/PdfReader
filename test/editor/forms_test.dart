import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/features/editor/forms/form_engine.dart';
import 'package:pdfreader/features/editor/forms/form_fill_controller.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_fixtures.dart';

void main() {
  setUpAll(() async => pdfrxInitialize());

  test('reads, fills (text, checkbox, choice) and re-reads form fields', () async {
    final doc = await PdfDocument.openData(await makeFormPdf());
    final c = FormFillController(document: doc);
    await c.load();
    expect(c.error, isNull);
    final byName = {for (final f in c.fields) f.name: f};
    expect(byName.keys, containsAll(['fullName', 'agree', 'color']));
    final name = byName['fullName']!, agree = byName['agree']!, color = byName['color']!;
    expect(name.kind, FormFieldKind.text);
    expect(agree.kind, FormFieldKind.checkbox);
    expect(agree.checked, isFalse);
    expect(color.kind, FormFieldKind.combo);
    expect(color.options, ['Red', 'Green', 'Blue']);

    await c.setText(name, 'Ada Lovelace');
    await c.setChecked(agree, true);
    await c.setSelection(color, {2});
    expect(c.textOf(name), 'Ada Lovelace');
    expect(c.isChecked(agree), isTrue);

    // Undo / redo through the shared stack.
    await c.undoStack.undo();
    expect(c.selectionOf(color), color.selected);
    await c.undoStack.redo();
    expect(c.selectionOf(color), {2});

    final bytes = await c.buildCopy();
    final out = await PdfDocument.openData(bytes);
    final fields = await FormEngine().readFields(Uint8List.fromList(bytes));
    final after = {for (final f in fields) f.name: f};
    expect(after['fullName']!.value, 'Ada Lovelace');
    expect(after['agree']!.checked, isTrue);
    expect(after['color']!.value, 'Blue');
    // Source untouched.
    final again = FormFillController(document: doc);
    await again.load();
    expect(again.fields.firstWhere((f) => f.name == 'fullName').value, isNot('Ada Lovelace'));

    // Flattened copy has no widgets left.
    final flat = await c.buildCopy(flatten: true);
    expect(await FormEngine().readFields(flat), isEmpty);

    c.dispose();
    again.dispose();
    await out.dispose();
    await doc.dispose();
  });

  test('document without a form yields no fields', () async {
    final doc = await PdfDocument.openData(await makePdf(1));
    final c = FormFillController(document: doc);
    await c.load();
    expect(c.fields, isEmpty);
    expect(c.error, isNull);
    c.dispose();
    await doc.dispose();
  });
}
