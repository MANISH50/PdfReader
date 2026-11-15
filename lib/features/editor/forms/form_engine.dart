import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:material_ui/material_ui.dart' show Rect;
import 'package:pdfium_dart/pdfium_dart.dart'
    show
        FPDF_ANNOT_WIDGET,
        FPDF_DOCUMENT,
        FPDF_FORMFIELD_CHECKBOX,
        FPDF_FORMFIELD_COMBOBOX,
        FPDF_FORMFIELD_LISTBOX,
        FPDF_FORMFIELD_PUSHBUTTON,
        FPDF_FORMFIELD_RADIOBUTTON,
        FPDF_FORMFIELD_SIGNATURE,
        FPDF_FORMFIELD_TEXTFIELD,
        FPDF_FORMFILLINFO,
        FPDF_FORMHANDLE,
        FPDF_ANNOTATION,
        FPDF_PAGE,
        PDFium;
import 'package:pdfrx/pdfrx.dart';

import '../engine/pdfium_native.dart';

enum FormFieldKind { text, checkbox, radio, combo, list, button, signature, unknown }

/// One widget of an AcroForm field. Radio groups have several widgets with
/// the same [name]. [rect] is in PDF points relative to the page box origin
/// (same space as annotations).
class FormFieldInfo {
  const FormFieldInfo({
    required this.page,
    required this.annotIndex,
    required this.name,
    required this.kind,
    required this.rect,
    this.value = '',
    this.checked = false,
    this.exportValue = '',
    this.options = const [],
    this.selected = const {},
    this.readOnly = false,
    this.multiline = false,
    this.multiSelect = false,
  });

  final int page;
  final int annotIndex;
  final String name;
  final FormFieldKind kind;
  final Rect rect;
  final String value;
  final bool checked;
  final String exportValue;
  final List<String> options;
  final Set<int> selected;
  final bool readOnly;
  final bool multiline;
  final bool multiSelect;

  /// Stable key of this widget within the document.
  String get key => 'p${page}_a$annotIndex';

  bool get isEditable =>
      !readOnly &&
      const {FormFieldKind.text, FormFieldKind.checkbox, FormFieldKind.radio, FormFieldKind.combo, FormFieldKind.list}
          .contains(kind);
}

/// A requested change to one widget.
sealed class FormEdit {
  const FormEdit(this.key);
  final String key;
}

class TextEdit extends FormEdit {
  const TextEdit(super.key, this.text);
  final String text;
}

/// Checkbox state, or "select this radio button" when [checked] is true.
class CheckEdit extends FormEdit {
  const CheckEdit(super.key, this.checked);
  final bool checked;
}

class ChoiceEdit extends FormEdit {
  const ChoiceEdit(super.key, this.selected);
  final Set<int> selected;
}

const int _flagReadOnly = 1;
const int _flagMultiline = 1 << 12;
const int _flagMultiSelect = 1 << 21;

/// Reads and fills AcroForm fields through PDFium's form-fill API
/// (FPDFDOC_InitFormFillEnvironment + FORM_* + FPDFAnnot_*), on a private
/// copy of the document so pdfrx's own form environment is untouched.
///
/// Values are written exactly as an interactive viewer would (focus, select
/// all, replace text / click / select option, kill focus), so PDFium
/// regenerates the widget appearance streams. XFA forms and JavaScript are
/// not supported (PDFium build has neither).
class FormEngine {
  FormEngine({this.maxFields = 5000});
  final int maxFields;

  Future<List<FormFieldInfo>> readFields(Uint8List bytes) => NativePdf.read(bytes, maxFields, _readTask);

  /// Applies [edits] and returns the new PDF bytes. With [flatten], form
  /// fields are burned into page content (no longer editable).
  Future<Uint8List> apply(Uint8List bytes, List<FormEdit> edits, {bool flatten = false}) =>
      NativePdf.edit(bytes, (edits: edits, flatten: flatten), _applyTask);

  static List<FormFieldInfo> _readTask(FPDF_DOCUMENT doc, int maxFields) =>
      _withForm(doc, (p, form) => _read(p, doc, form, maxFields));

  static void _applyTask(FPDF_DOCUMENT doc, ({List<FormEdit> edits, bool flatten}) m) {
    _withForm(doc, (p, form) => _apply(p, doc, form, m.edits));
    if (m.flatten) {
      final p = NativePdf.pdfium;
      for (var i = 0; i < p.FPDF_GetPageCount(doc); i++) {
        final page = p.FPDF_LoadPage(doc, i);
        if (page == nullptr) continue;
        p.FPDFPage_Flatten(page, 1 /* FLAT_PRINT */);
        p.FPDF_ClosePage(page);
      }
    }
  }

  static T _withForm<T>(FPDF_DOCUMENT doc, T Function(PDFium p, FPDF_FORMHANDLE form) f) {
    final p = NativePdf.pdfium;
    final info = calloc<FPDF_FORMFILLINFO>();
    info.ref.version = 1;
    final form = p.FPDFDOC_InitFormFillEnvironment(doc, info);
    try {
      return f(p, form);
    } finally {
      if (form != nullptr) p.FPDFDOC_ExitFormFillEnvironment(form);
      calloc.free(info);
    }
  }

  static FormFieldKind _kind(int t) => switch (t) {
        FPDF_FORMFIELD_TEXTFIELD => FormFieldKind.text,
        FPDF_FORMFIELD_CHECKBOX => FormFieldKind.checkbox,
        FPDF_FORMFIELD_RADIOBUTTON => FormFieldKind.radio,
        FPDF_FORMFIELD_COMBOBOX => FormFieldKind.combo,
        FPDF_FORMFIELD_LISTBOX => FormFieldKind.list,
        FPDF_FORMFIELD_PUSHBUTTON => FormFieldKind.button,
        FPDF_FORMFIELD_SIGNATURE => FormFieldKind.signature,
        _ => FormFieldKind.unknown,
      };

  static List<FormFieldInfo> _read(PDFium p, FPDF_DOCUMENT doc, FPDF_FORMHANDLE form, int maxFields) {
    final out = <FormFieldInfo>[];
    if (form == nullptr || p.FPDF_GetFormType(doc) == 0) return out;
    final count = p.FPDF_GetPageCount(doc);
    for (var i = 0; i < count && out.length < maxFields; i++) {
      final page = p.FPDF_LoadPage(doc, i);
      if (page == nullptr) continue;
      p.FORM_OnAfterLoadPage(page, form);
      try {
        final origin = NativePdf.withRect((r) {
          p.FPDF_GetPageBoundingBox(page, r);
          return (r.ref.left, r.ref.bottom);
        });
        final n = p.FPDFPage_GetAnnotCount(page);
        for (var j = 0; j < n && out.length < maxFields; j++) {
          final annot = p.FPDFPage_GetAnnot(page, j);
          if (annot == nullptr) continue;
          try {
            if (p.FPDFAnnot_GetSubtype(annot) != FPDF_ANNOT_WIDGET) continue;
            out.add(_info(p, form, annot, i + 1, j, origin));
          } finally {
            p.FPDFPage_CloseAnnot(annot);
          }
        }
      } finally {
        p.FORM_OnBeforeClosePage(page, form);
        p.FPDF_ClosePage(page);
      }
    }
    return out;
  }

  static FormFieldInfo _info(PDFium p, FPDF_FORMHANDLE form, FPDF_ANNOTATION annot, int page, int index,
      (double, double) origin) {
    final kind = _kind(p.FPDFAnnot_GetFormFieldType(form, annot));
    final flags = p.FPDFAnnot_GetFormFieldFlags(form, annot);
    final rect = NativePdf.withRect((r) {
      p.FPDFAnnot_GetRect(annot, r);
      return Rect.fromLTRB(r.ref.left - origin.$1, r.ref.bottom - origin.$2, r.ref.right - origin.$1,
          r.ref.top - origin.$2);
    });
    final options = <String>[];
    final selected = <int>{};
    if (kind == FormFieldKind.combo || kind == FormFieldKind.list) {
      final n = p.FPDFAnnot_GetOptionCount(form, annot);
      for (var k = 0; k < n && k < 1000; k++) {
        options.add(NativePdf.readWide((b, l) => p.FPDFAnnot_GetOptionLabel(form, annot, k, b, l)));
        if (p.FPDFAnnot_IsOptionSelected(form, annot, k) != 0) selected.add(k);
      }
    }
    final isToggle = kind == FormFieldKind.checkbox || kind == FormFieldKind.radio;
    return FormFieldInfo(
      page: page,
      annotIndex: index,
      name: NativePdf.readWide((b, l) => p.FPDFAnnot_GetFormFieldName(form, annot, b, l)),
      kind: kind,
      rect: Rect.fromLTRB(
          rect.left < rect.right ? rect.left : rect.right,
          rect.top < rect.bottom ? rect.top : rect.bottom,
          rect.left < rect.right ? rect.right : rect.left,
          rect.top < rect.bottom ? rect.bottom : rect.top),
      value: NativePdf.readWide((b, l) => p.FPDFAnnot_GetFormFieldValue(form, annot, b, l)),
      checked: isToggle && p.FPDFAnnot_IsChecked(form, annot) != 0,
      exportValue:
          isToggle ? NativePdf.readWide((b, l) => p.FPDFAnnot_GetFormFieldExportValue(form, annot, b, l)) : '',
      options: options,
      selected: selected,
      readOnly: flags & _flagReadOnly != 0,
      multiline: kind == FormFieldKind.text && flags & _flagMultiline != 0,
      multiSelect: kind == FormFieldKind.list && flags & _flagMultiSelect != 0,
    );
  }

  static void _apply(PDFium p, FPDF_DOCUMENT doc, FPDF_FORMHANDLE form, List<FormEdit> edits) {
    if (form == nullptr) throw const PdfException('Document has no form');
    final byPage = <int, List<(int, FormEdit)>>{};
    final re = RegExp(r'^p(\d+)_a(\d+)$');
    for (final e in edits) {
      final m = re.firstMatch(e.key);
      if (m == null) continue;
      (byPage[int.parse(m[1]!)] ??= []).add((int.parse(m[2]!), e));
    }
    final count = p.FPDF_GetPageCount(doc);
    for (final entry in byPage.entries) {
      if (entry.key < 1 || entry.key > count) continue;
      final page = p.FPDF_LoadPage(doc, entry.key - 1);
      if (page == nullptr) continue;
      p.FORM_OnAfterLoadPage(page, form);
      try {
        final annots = p.FPDFPage_GetAnnotCount(page);
        for (final (index, edit) in entry.value) {
          if (index < 0 || index >= annots) continue;
          final annot = p.FPDFPage_GetAnnot(page, index);
          if (annot == nullptr) continue;
          try {
            if (p.FPDFAnnot_GetSubtype(annot) != FPDF_ANNOT_WIDGET) continue;
            if (p.FPDFAnnot_GetFormFieldFlags(form, annot) & _flagReadOnly != 0) continue;
            _applyOne(p, form, page, annot, edit);
          } finally {
            p.FPDFPage_CloseAnnot(annot);
          }
        }
      } finally {
        p.FORM_ForceToKillFocus(form);
        p.FORM_OnBeforeClosePage(page, form);
        p.FPDF_ClosePage(page);
      }
    }
  }

  static void _applyOne(PDFium p, FPDF_FORMHANDLE form, FPDF_PAGE page, FPDF_ANNOTATION annot, FormEdit edit) {
    final kind = _kind(p.FPDFAnnot_GetFormFieldType(form, annot));
    switch (edit) {
      case TextEdit(:final text) when kind == FormFieldKind.text || kind == FormFieldKind.combo:
        if (p.FORM_SetFocusedAnnot(form, annot) == 0) return;
        p.FORM_SelectAllText(form, page);
        final w = NativePdf.wide(text);
        try {
          p.FORM_ReplaceSelection(form, page, w);
        } finally {
          calloc.free(w);
        }
        p.FORM_ForceToKillFocus(form);
      case CheckEdit(:final checked) when kind == FormFieldKind.checkbox || kind == FormFieldKind.radio:
        final isOn = p.FPDFAnnot_IsChecked(form, annot) != 0;
        if (isOn == checked) return;
        // Radio buttons cannot be switched off by clicking; select another.
        if (kind == FormFieldKind.radio && !checked) return;
        final (x, y) = NativePdf.withRect((r) {
          p.FPDFAnnot_GetRect(annot, r);
          return ((r.ref.left + r.ref.right) / 2, (r.ref.top + r.ref.bottom) / 2);
        });
        p.FORM_OnMouseMove(form, page, 0, x, y);
        p.FORM_OnLButtonDown(form, page, 0, x, y);
        p.FORM_OnLButtonUp(form, page, 0, x, y);
        p.FORM_ForceToKillFocus(form);
      case ChoiceEdit(:final selected) when kind == FormFieldKind.combo || kind == FormFieldKind.list:
        if (p.FORM_SetFocusedAnnot(form, annot) == 0) return;
        final n = p.FPDFAnnot_GetOptionCount(form, annot);
        if (kind == FormFieldKind.list) {
          for (var k = 0; k < n; k++) {
            if (!selected.contains(k) && p.FPDFAnnot_IsOptionSelected(form, annot, k) != 0) {
              p.FORM_SetIndexSelected(form, page, k, 0);
            }
          }
        }
        for (final k in selected) {
          if (k >= 0 && k < n) p.FORM_SetIndexSelected(form, page, k, 1);
        }
        p.FORM_ForceToKillFocus(form);
      default:
        break;
    }
  }
}
