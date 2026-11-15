import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfium_dart/pdfium_dart.dart'
    show FPDF_DOCUMENT, FPDF_FILEWRITE, FPDF_WCHAR, FS_RECTF;
import 'package:pdfrx/pdfrx.dart';

/// Helpers around raw PDFium used by the flattener and the form filler.
///
/// PDFium is not thread-safe, and pdfrx installs font callbacks that only
/// work on its worker isolate (calling them from another isolate aborts the
/// process). So all native work runs on pdfrx's PDFium worker through
/// `PdfrxEntryFunctions.instance.compute`. Tasks must be static/top-level
/// functions and messages plain Dart data.
abstract final class NativePdf {
  static pdfium_bindings.PDFium? _pdfium;

  /// Same shared library as pdfrx (dlopen is reference counted), so it
  /// shares PDFium's global state.
  static pdfium_bindings.PDFium get pdfium =>
      _pdfium ??= pdfium_bindings.getPdfium(modulePath: Pdfrx.pdfiumModulePath);

  /// Loads [bytes] as a private PDFium document on the PDFium worker, runs
  /// [task] on it and returns the saved result (full rewrite, no incremental
  /// update). The document and its buffer are always released.
  static Future<Uint8List> edit<M>(
    Uint8List bytes,
    M message,
    void Function(FPDF_DOCUMENT doc, M message) task,
  ) =>
      _unwrap(PdfrxEntryFunctions.instance
          .compute((p) => editSync(p.$1, (doc) => p.$3(doc, p.$2)), (bytes, message, task)));

  /// Like [edit] but returns a value instead of saving.
  static Future<T> read<M, T>(Uint8List bytes, M message, T Function(FPDF_DOCUMENT doc, M message) task) =>
      _unwrap(PdfrxEntryFunctions.instance
          .compute((p) => _withDoc(p.$1, (doc) => p.$3(doc, p.$2)), (bytes, message, task)));

  /// Worker exceptions arrive wrapped; surface them as [PdfException] with a
  /// generic message (never echo engine text to the user).
  static Future<T> _unwrap<T>(Future<T> f) async {
    try {
      return await f;
    } catch (e) {
      throw PdfException('Native PDF operation failed (${e.toString().split('\n').first})');
    }
  }

  static Uint8List editSync(Uint8List bytes, void Function(FPDF_DOCUMENT doc) task) =>
      _withDoc(bytes, (doc) {
        task(doc);
        return saveSync(doc);
      });

  static T _withDoc<T>(Uint8List bytes, T Function(FPDF_DOCUMENT doc) task) {
    final p = pdfium;
    final buf = malloc<Uint8>(bytes.length);
    FPDF_DOCUMENT doc = nullptr;
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      doc = p.FPDF_LoadMemDocument64(buf.cast(), bytes.length, nullptr);
      if (doc == nullptr) {
        throw PdfException('PDFium could not load document (error ${p.FPDF_GetLastError()})');
      }
      return task(doc);
    } finally {
      if (doc != nullptr) p.FPDF_CloseDocument(doc);
      malloc.free(buf);
    }
  }

  /// Serialises [doc] with FPDF_SaveAsCopy (FPDF_NO_INCREMENTAL).
  static Uint8List saveSync(FPDF_DOCUMENT doc) {
    final out = BytesBuilder(copy: true);
    int write(Pointer<FPDF_FILEWRITE> self, Pointer<Void> data, int size) {
      out.add(data.cast<Uint8>().asTypedList(size));
      return 1;
    }

    final callable = NativeCallable<Int Function(Pointer<FPDF_FILEWRITE>, Pointer<Void>, UnsignedLong)>.isolateLocal(
        write,
        exceptionalReturn: 0);
    final fw = calloc<FPDF_FILEWRITE>();
    try {
      fw.ref.version = 1;
      fw.ref.WriteBlock = callable.nativeFunction;
      final ok = pdfium.FPDF_SaveAsCopy(doc, fw, 2);
      if (ok == 0) throw const PdfException('PDFium failed to save document');
      return out.takeBytes();
    } finally {
      calloc.free(fw);
      callable.close();
    }
  }

  /// Allocates a NUL-terminated UTF-16LE string. Free with [calloc.free].
  static Pointer<FPDF_WCHAR> wide(String s) {
    final units = s.codeUnits;
    final ptr = calloc<FPDF_WCHAR>(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr;
  }

  /// Reads a PDFium "two-call" UTF-16 getter (first call returns the byte
  /// length including the terminator). Caps at 64 KiB for safety.
  static String readWide(int Function(Pointer<FPDF_WCHAR> buf, int len) getter) {
    final len = getter(nullptr, 0);
    if (len <= 2) return '';
    final capped = len > 65536 ? 65536 : len;
    final buf = calloc<Uint8>(capped);
    try {
      getter(buf.cast(), capped);
      final units = buf.cast<Uint16>().asTypedList(capped ~/ 2);
      var end = units.indexOf(0);
      if (end < 0) end = units.length;
      return String.fromCharCodes(units.sublist(0, end));
    } finally {
      calloc.free(buf);
    }
  }

  /// Runs [f] with a temporary FS_RECTF.
  static T withRect<T>(T Function(Pointer<FS_RECTF> r) f) {
    final r = calloc<FS_RECTF>();
    try {
      return f(r);
    } finally {
      calloc.free(r);
    }
  }
}
