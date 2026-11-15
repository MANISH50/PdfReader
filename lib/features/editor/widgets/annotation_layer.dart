import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/models/annotation.dart';
import '../annotation_controller.dart';
import '../editor_tools.dart';
import '../model/annotation_ops.dart';
import '../model/page_transform.dart';
import '../model/text_layout.dart';
import '../signature/signature_store.dart';
import 'annotation_painter.dart';
import 'text_input_dialog.dart';

/// Overlay that renders and edits the annotations of one page.
///
/// Stack it exactly over the rendered page. [transform] maps PDF points
/// (unrotated page, origin bottom-left, see annotation_ops.dart) to this
/// widget's local coordinates — build it with [pdfToViewMatrix].
///
/// With [EditorTool.none] the layer ignores all pointers. With
/// [EditorTool.select] it only claims pointers that land on an annotation
/// (or on the selected annotation's handles), so scrolling/zooming the
/// viewer keeps working elsewhere. Drawing tools claim every pointer on the
/// page.
class AnnotationLayer extends StatefulWidget {
  const AnnotationLayer({
    super.key,
    required this.page,
    required this.pageSize,
    required this.transform,
    required this.controller,
    required this.tool,
    this.signatureImages,
    this.onRequestSignature,
  });

  /// 1-based page number.
  final int page;

  /// Unrotated page size in PDF points.
  final Size pageSize;
  final Matrix4 transform;
  final AnnotationController controller;
  final EditorToolState tool;
  final SignatureImageCache? signatureImages;

  /// Called when the signature tool is used but no signature is chosen yet;
  /// should let the user pick/create one and set [EditorToolState.signatureId].
  final Future<void> Function()? onRequestSignature;

  @override
  State<AnnotationLayer> createState() => AnnotationLayerState();
}

enum _Drag { none, draw, move, resize }

@visibleForTesting
class AnnotationLayerState extends State<AnnotationLayer> {
  Annotation? _preview;
  _Drag _drag = _Drag.none;
  Offset? _start; // pdf
  List<Offset> _stroke = [];
  Annotation? _dragOrigin;
  Rect? _resizeFrame;
  int _resizeCorner = 0; // 0 tl(visual) ... uses pdf corners: 0 (l,t) 1 (r,t) 2 (l,b) 3 (r,b)

  late Matrix4 _inverse;

  @override
  void initState() {
    super.initState();
    _inverse = _invert(widget.transform);
  }

  @override
  void didUpdateWidget(AnnotationLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transform != widget.transform) _inverse = _invert(widget.transform);
  }

  static Matrix4 _invert(Matrix4 m) {
    final inv = Matrix4.zero();
    return inv.copyInverse(m) == 0 ? Matrix4.identity() : inv;
  }

  double get _scale => matrixScale(widget.transform);
  double get _tolerancePt => 10 / (_scale == 0 ? 1 : _scale);

  Offset _toPdf(Offset local) {
    final p = transformPoint(_inverse, local);
    return Offset(p.dx.clamp(0.0, widget.pageSize.width), p.dy.clamp(0.0, widget.pageSize.height));
  }

  List<Annotation> get _pageItems => widget.controller.forPage(widget.page);

  Annotation? get _selectedOnPage {
    final s = widget.controller.selected;
    return s != null && s.page == widget.page ? s : null;
  }

  int? _handleAt(Offset pdf) {
    final s = _selectedOnPage;
    if (s == null || s is NoteAnnotation || s is TextMarkupAnnotation) return null;
    final r = annotationBounds(s).inflate(3 / (_scale == 0 ? 1 : _scale));
    final corners = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - pdf).distance <= _tolerancePt * 1.4) return i;
    }
    return null;
  }

  /// Hit predicate for select mode (widget-local coordinates).
  bool _claims(Offset local) {
    final t = widget.tool.tool;
    if (t == EditorTool.none) return false;
    if (t != EditorTool.select) return true;
    final pdf = transformPoint(_inverse, local);
    return _handleAt(pdf) != null || hitTestAll(_pageItems, pdf, _tolerancePt) != null;
  }

  // ---- Gestures --------------------------------------------------------------

  Future<void> _onTapUp(TapUpDetails d) => _handleTap(_toPdf(d.localPosition));

  Future<void> _handleTap(Offset pdf) async {
    final tool = widget.tool;
    final c = widget.controller;
    switch (tool.tool) {
      case EditorTool.select:
        final hit = hitTestAll(_pageItems, pdf, _tolerancePt);
        if (hit != null && hit.id == c.selectedId && (hit is NoteAnnotation || hit is TextBoxAnnotation)) {
          await _editText(hit);
        } else {
          c.select(hit?.id);
        }
      case EditorTool.note:
        final text = await showTextInputDialog(context, title: 'Note', hint: 'Write a note');
        if (text == null || text.trim().isEmpty) return;
        final anchor = Offset(math.min(pdf.dx, widget.pageSize.width - kNoteIconSize),
            math.max(pdf.dy, kNoteIconSize));
        await c.add(NoteAnnotation(
            id: newAnnotationId(), page: widget.page, color: tool.color, createdAt: DateTime.now(),
            anchor: anchor, text: text.trim()));
      case EditorTool.textBox:
        await _createTextBox(Rect.fromLTWH(pdf.dx, pdf.dy - 1, 200, 1), fixedHeight: false);
      case EditorTool.signature:
        await _placeSignature(pdf);
      default:
        break;
    }
  }

  Future<void> _editText(Annotation a) async {
    final current = switch (a) {
      NoteAnnotation(:final text) => text,
      TextBoxAnnotation(:final text) => text,
      _ => '',
    };
    final res = await showTextInputDialog(context,
        title: a is NoteAnnotation ? 'Note' : 'Text box', initial: current, allowDelete: true);
    if (res == null) return;
    if (res == kDeleteResult || res.trim().isEmpty) {
      await widget.controller.remove(a.id);
    } else if (res != current) {
      await widget.controller.editText(a.id, res);
    }
  }

  Future<void> _createTextBox(Rect r, {required bool fixedHeight}) async {
    final tool = widget.tool;
    final text = await showTextInputDialog(context, title: 'Text box', hint: 'Type text');
    if (text == null || text.trim().isEmpty) return;
    final width = math.max(40.0, math.min(r.width, widget.pageSize.width - r.left));
    final lines = wrapText(text, tool.fontSize, width - 2 * kTextBoxPadding).length;
    final needed = lines * tool.fontSize * kTextBoxLineHeight + 2 * kTextBoxPadding;
    final height = fixedHeight ? math.max(r.height, needed) : needed;
    // r.bottom is the visual top edge in PDF space.
    final top = math.min(r.bottom, widget.pageSize.height);
    final bounds = Rect.fromLTRB(r.left, math.max(0, top - height), r.left + width, top);
    final a = TextBoxAnnotation(
        id: newAnnotationId(), page: widget.page, color: tool.color, createdAt: DateTime.now(),
        bounds: bounds, text: text, fontSize: tool.fontSize);
    await widget.controller.add(a);
  }

  Future<void> _placeSignature(Offset pdf) async {
    final tool = widget.tool;
    if (tool.signatureId == null) {
      await widget.onRequestSignature?.call();
      if (tool.signatureId == null) return;
    }
    final id = tool.signatureId!;
    final img = widget.signatureImages?.get(id);
    final aspect = img == null || img.height == 0 ? 3.0 : img.width / img.height;
    final w = math.min(160.0, widget.pageSize.width * 0.6);
    final h = w / aspect;
    final left = (pdf.dx - w / 2).clamp(0.0, math.max(0.0, widget.pageSize.width - w));
    final bottom = (pdf.dy - h / 2).clamp(0.0, math.max(0.0, widget.pageSize.height - h));
    final a = SignatureAnnotation(
        id: newAnnotationId(), page: widget.page, color: const Color(0xFF000000), createdAt: DateTime.now(),
        bounds: Rect.fromLTWH(left.toDouble(), bottom.toDouble(), w, h), signatureId: id);
    await widget.controller.add(a);
    widget.controller.select(a.id);
    tool.tool = EditorTool.select;
  }

  void _onPanStart(DragStartDetails d) {
    final pdf = _toPdf(d.localPosition);
    _start = pdf;
    final t = widget.tool.tool;
    if (t == EditorTool.select) {
      final handle = _handleAt(pdf);
      final sel = _selectedOnPage;
      if (handle != null && sel != null) {
        _drag = _Drag.resize;
        _resizeCorner = handle;
        _dragOrigin = sel;
        _resizeFrame = AnnotationController.resizeFrameOf(sel);
        return;
      }
      final hit = hitTestAll(_pageItems, pdf, _tolerancePt);
      if (hit != null) {
        widget.controller.select(hit.id);
        _drag = _Drag.move;
        _dragOrigin = hit;
      }
      return;
    }
    _drag = _Drag.draw;
    _stroke = [pdf];
    _updateDrawPreview(pdf);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final pdf = _toPdf(d.localPosition);
    switch (_drag) {
      case _Drag.draw:
        _updateDrawPreview(pdf);
      case _Drag.move:
        setState(() => _preview = translateAnnotation(_dragOrigin!, pdf - _start!));
      case _Drag.resize:
        final f = _resizeFrame!;
        var l = f.left, t = f.top, r = f.right, b = f.bottom;
        switch (_resizeCorner) {
          case 0:
            l = pdf.dx;
            t = pdf.dy;
          case 1:
            r = pdf.dx;
            t = pdf.dy;
          case 2:
            l = pdf.dx;
            b = pdf.dy;
          default:
            r = pdf.dx;
            b = pdf.dy;
        }
        final to = normalizeRect(Rect.fromLTRB(l, t, r, b));
        if (to.width < 4 || to.height < 4) return;
        setState(() => _preview = resizeAnnotation(_dragOrigin!, f, to));
      case _Drag.none:
        break;
    }
  }

  void _updateDrawPreview(Offset pdf) {
    final tool = widget.tool;
    final t = tool.tool;
    final s = _start!;
    Annotation? p;
    if (t == EditorTool.ink) {
      _stroke.add(pdf);
      p = InkAnnotation(
          id: '_preview', page: widget.page, color: tool.color, strokeWidth: tool.strokeWidth,
          strokes: [List.of(_stroke)]);
    } else if (t.isShape) {
      final shape = t.shapeKind!;
      final raw = Rect.fromLTRB(s.dx, s.dy, pdf.dx, pdf.dy);
      p = ShapeAnnotation(
          id: '_preview', page: widget.page, color: tool.color, strokeWidth: tool.strokeWidth, shape: shape,
          bounds: isDirectionalShape(shape) ? raw : normalizeRect(raw));
    } else if (t.isMarkup) {
      p = TextMarkupAnnotation(
          id: '_preview', page: widget.page, color: tool.color, kind: t.markupKind!,
          rects: [normalizeRect(Rect.fromLTRB(s.dx, s.dy, pdf.dx, pdf.dy))]);
    } else if (t == EditorTool.textBox || t == EditorTool.signature || t == EditorTool.note) {
      p = ShapeAnnotation(
          id: '_preview', page: widget.page, color: const Color(0xFF3B5BDB), strokeWidth: 0.75,
          shape: ShapeKind.rectangle, bounds: normalizeRect(Rect.fromLTRB(s.dx, s.dy, pdf.dx, pdf.dy)));
    }
    setState(() => _preview = p);
  }

  Future<void> _onPanEnd(DragEndDetails d) async {
    final drag = _drag;
    final preview = _preview;
    final origin = _dragOrigin;
    _drag = _Drag.none;
    _dragOrigin = null;
    final c = widget.controller;
    final tool = widget.tool;
    final minPt = 6 / (_scale == 0 ? 1 : _scale);
    try {
      switch (drag) {
        case _Drag.move:
        case _Drag.resize:
          if (preview != null && origin != null) {
            await c.update(preview, label: drag == _Drag.move ? 'Move annotation' : 'Resize annotation');
          }
        case _Drag.draw:
          if (preview == null) return;
          final now = DateTime.now();
          switch (tool.tool) {
            case EditorTool.ink:
              final pts = simplifyStroke(_stroke);
              await c.add(InkAnnotation(
                  id: newAnnotationId(), page: widget.page, color: tool.color, createdAt: now,
                  strokeWidth: tool.strokeWidth, strokes: [pts]));
            case final t when t.isShape:
              final b = (preview as ShapeAnnotation).bounds;
              if (normalizeRect(b).longestSide < minPt) return;
              await c.add(ShapeAnnotation(
                  id: newAnnotationId(), page: widget.page, color: tool.color, createdAt: now,
                  shape: preview.shape, bounds: b, strokeWidth: tool.strokeWidth));
            case final t when t.isMarkup:
              final r = (preview as TextMarkupAnnotation).rects.first;
              if (r.width < minPt || r.height < minPt) return;
              await c.addTextMarkup(page: widget.page, kind: t.markupKind!, rects: [r], color: tool.color);
            case EditorTool.textBox:
              final r = (preview as ShapeAnnotation).bounds;
              setState(() => _preview = null);
              if (r.width < minPt) return;
              await _createTextBox(r, fixedHeight: true);
            case EditorTool.signature:
            case EditorTool.note:
              setState(() => _preview = null);
              await _handleTap(_stroke.first);
            default:
              break;
          }
        case _Drag.none:
          break;
      }
    } finally {
      if (mounted) setState(() => _preview = null);
      _stroke = [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge([widget.controller, widget.tool, ?widget.signatureImages]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final t = widget.tool.tool;
        final paint = CustomPaint(
          size: Size.infinite,
          painter: AnnotationPainter(
            annotations: _pageItems,
            matrix: widget.transform,
            images: widget.signatureImages,
            selectedId: t == EditorTool.select ? widget.controller.selectedId : null,
            preview: _preview,
            selectionColor: Theme.of(context).colorScheme.primary,
          ),
        );
        if (t == EditorTool.none) return IgnorePointer(child: paint);
        return _SelectiveHit(
          claims: _claims,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onTapUp: (d) => unawaited(_onTapUp(d)),
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: (d) => unawaited(_onPanEnd(d)),
            child: paint,
          ),
        );
      },
    );
  }
}

/// Only participates in hit testing where [claims] returns true.
class _SelectiveHit extends SingleChildRenderObjectWidget {
  const _SelectiveHit({required this.claims, super.child});
  final bool Function(Offset local) claims;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSelectiveHit(claims);

  @override
  void updateRenderObject(BuildContext context, _RenderSelectiveHit renderObject) =>
      renderObject.claims = claims;
}

class _RenderSelectiveHit extends RenderProxyBox {
  _RenderSelectiveHit(this.claims);
  bool Function(Offset local) claims;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || !claims(position)) return false;
    return super.hitTest(result, position: position);
  }
}
