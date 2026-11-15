import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:material_ui/material_ui.dart';

import '../../../ui/design_system/tokens.dart';
import '../model/annotation_ops.dart';
import '../widgets/annotation_painter.dart' show strokePath;
import 'signature_store.dart';

/// Full-screen signature pad. Draw with a finger/stylus; "Save" renders the
/// strokes, cropped to their bounds, into a transparent PNG stored in
/// [SignatureStore]. Pops with the new signature id (or null).
class SignaturePadScreen extends StatefulWidget {
  const SignaturePadScreen({super.key, required this.store});
  final SignatureStore store;

  static Future<String?> open(BuildContext context, SignatureStore store) => Navigator.of(context)
      .push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => SignaturePadScreen(store: store)));

  @override
  State<SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _SignaturePadScreenState extends State<SignaturePadScreen> {
  final List<List<Offset>> _strokes = [];
  Color _color = const Color(0xFF0B1F66);
  bool _saving = false;
  static const double _width = 3;

  Future<void> _save() async {
    if (_strokes.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final png = await renderSignaturePng(_strokes, _color, _width);
      final id = await widget.store.save(png);
      if (mounted) Navigator.pop(context, id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not save the signature')));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New signature'),
        actions: [
          IconButton(
            tooltip: 'Undo stroke',
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
            icon: const Icon(Icons.delete_outline),
          ),
          Padding(
            padding: const EdgeInsets.only(right: Space.sm),
            child: FilledButton(
              onPressed: _strokes.isEmpty || _saving ? null : () => unawaited(_save()),
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Space.md),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: Radii.card,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: ClipRRect(
                    borderRadius: Radii.card,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
                      onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
                      onPanEnd: (_) => setState(() {
                        _strokes.last = simplifyStroke(_strokes.last, minDistance: 1);
                      }),
                      child: CustomPaint(
                        painter: _PadPainter(_strokes, _color, _width, scheme.outlineVariant),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in const [Color(0xFF0B1F66), Color(0xFF000000), Color(0xFF1565C0)])
                    Semantics(
                      label: 'Ink colour',
                      selected: c == _color,
                      button: true,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() => _color = c),
                        child: SizedBox(
                          width: kMinTouchTarget,
                          height: kMinTouchTarget,
                          child: Center(
                            child: CircleAvatar(
                              radius: c == _color ? 16 : 12,
                              backgroundColor: c,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.color, this.width, this.guide);
  final List<List<Offset>> strokes;
  final Color color;
  final double width;
  final Color guide;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * 0.7;
    canvas.drawLine(Offset(24, y), Offset(size.width - 24, y), Paint()..color = guide);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    for (final s in strokes) {
      canvas.drawPath(strokePath(s), p);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}

/// Renders [strokes] (logical px) to a transparent PNG cropped to the ink,
/// at 3x resolution, capped at 2048 px on the longest side.
Future<Uint8List> renderSignaturePng(List<List<Offset>> strokes, Color color, double width) async {
  final all = strokes.expand((s) => s).toList();
  var bounds = Rect.fromPoints(all.first, all.first);
  for (final p in all) {
    bounds = bounds.expandToInclude(Rect.fromPoints(p, p));
  }
  bounds = bounds.inflate(width + 2);
  var scale = 3.0;
  final longest = math.max(bounds.width, bounds.height);
  if (longest * scale > 2048) scale = 2048 / longest;
  final w = math.max(1, (bounds.width * scale).ceil());
  final h = math.max(1, (bounds.height * scale).ceil());
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.scale(scale);
  canvas.translate(-bounds.left, -bounds.top);
  final p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color;
  for (final s in strokes) {
    canvas.drawPath(strokePath(s), p);
  }
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}
