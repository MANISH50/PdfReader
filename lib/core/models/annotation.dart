import 'dart:ui' show Color, Offset, Rect;

/// Annotations are stored in an app-private sidecar (per DocumentRef.id) and
/// flattened into the PDF on Save / Save as copy / Export. All geometry is in
/// **PDF page coordinates** (points, origin bottom-left, unrotated page), so
/// it is independent of zoom and screen size.
sealed class Annotation {
  const Annotation({required this.id, required this.page, required this.color, this.createdAt});

  final String id;

  /// 1-based page number.
  final int page;
  final Color color;
  final DateTime? createdAt;

  String get type;
  Map<String, Object?> toJson();

  Map<String, Object?> baseJson() => {
        'type': type,
        'id': id,
        'page': page,
        'color': color.toARGB32(),
        'createdAt': createdAt?.toIso8601String(),
      };

  static Annotation fromJson(Map<String, Object?> j) {
    final id = j['id']! as String;
    final page = (j['page']! as num).toInt();
    final color = Color((j['color']! as num).toInt());
    final createdAt = DateTime.tryParse((j['createdAt'] as String?) ?? '');
    List<Rect> rects() => [for (final r in j['rects']! as List) _rect(r as List)];
    return switch (j['type']) {
      'highlight' => TextMarkupAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          kind: MarkupKind.highlight, rects: rects(), text: j['text'] as String?),
      'underline' => TextMarkupAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          kind: MarkupKind.underline, rects: rects(), text: j['text'] as String?),
      'strikeout' => TextMarkupAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          kind: MarkupKind.strikeout, rects: rects(), text: j['text'] as String?),
      'note' => NoteAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          anchor: _offset(j['anchor']! as List), text: j['text']! as String),
      'ink' => InkAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          strokeWidth: (j['strokeWidth']! as num).toDouble(),
          strokes: [
            for (final s in j['strokes']! as List) [for (final pt in s as List) _offset(pt as List)]
          ]),
      'shape' => ShapeAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          shape: ShapeKind.values.byName(j['shape']! as String),
          bounds: _rect(j['bounds']! as List),
          strokeWidth: (j['strokeWidth']! as num).toDouble()),
      'textbox' => TextBoxAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          bounds: _rect(j['bounds']! as List), text: j['text']! as String,
          fontSize: (j['fontSize']! as num).toDouble()),
      'signature' => SignatureAnnotation(
          id: id, page: page, color: color, createdAt: createdAt,
          bounds: _rect(j['bounds']! as List), signatureId: j['signatureId']! as String),
      final t => throw FormatException('Unknown annotation type $t'),
    };
  }
}

enum MarkupKind { highlight, underline, strikeout }

enum ShapeKind { rectangle, ellipse, line, arrow }

class TextMarkupAnnotation extends Annotation {
  const TextMarkupAnnotation({
    required super.id, required super.page, required super.color, super.createdAt,
    required this.kind, required this.rects, this.text,
  });
  final MarkupKind kind;
  final List<Rect> rects;
  final String? text;
  @override
  String get type => kind.name;
  @override
  Map<String, Object?> toJson() =>
      {...baseJson(), 'rects': [for (final r in rects) _rectJson(r)], 'text': text};
}

class NoteAnnotation extends Annotation {
  const NoteAnnotation({
    required super.id, required super.page, required super.color, super.createdAt,
    required this.anchor, required this.text,
  });
  final Offset anchor;
  final String text;
  @override
  String get type => 'note';
  @override
  Map<String, Object?> toJson() => {...baseJson(), 'anchor': _offsetJson(anchor), 'text': text};
}

class InkAnnotation extends Annotation {
  const InkAnnotation({
    required super.id, required super.page, required super.color, super.createdAt,
    required this.strokes, required this.strokeWidth,
  });
  final List<List<Offset>> strokes;
  final double strokeWidth;
  @override
  String get type => 'ink';
  @override
  Map<String, Object?> toJson() => {
        ...baseJson(),
        'strokeWidth': strokeWidth,
        'strokes': [for (final s in strokes) [for (final pt in s) _offsetJson(pt)]],
      };
}

class ShapeAnnotation extends Annotation {
  const ShapeAnnotation({
    required super.id, required super.page, required super.color, super.createdAt,
    required this.shape, required this.bounds, required this.strokeWidth,
  });
  final ShapeKind shape;
  final Rect bounds;
  final double strokeWidth;
  @override
  String get type => 'shape';
  @override
  Map<String, Object?> toJson() =>
      {...baseJson(), 'shape': shape.name, 'bounds': _rectJson(bounds), 'strokeWidth': strokeWidth};
}

class TextBoxAnnotation extends Annotation {
  const TextBoxAnnotation({
    required super.id, required super.page, required super.color, super.createdAt,
    required this.bounds, required this.text, required this.fontSize,
  });
  final Rect bounds;
  final String text;
  final double fontSize;
  @override
  String get type => 'textbox';
  @override
  Map<String, Object?> toJson() =>
      {...baseJson(), 'bounds': _rectJson(bounds), 'text': text, 'fontSize': fontSize};
}

/// [signatureId] refers to a PNG saved by the signature pad in app-private storage.
class SignatureAnnotation extends Annotation {
  const SignatureAnnotation({
    required super.id, required super.page, required super.color, super.createdAt,
    required this.bounds, required this.signatureId,
  });
  final Rect bounds;
  final String signatureId;
  @override
  String get type => 'signature';
  @override
  Map<String, Object?> toJson() =>
      {...baseJson(), 'bounds': _rectJson(bounds), 'signatureId': signatureId};
}

List<double> _rectJson(Rect r) => [r.left, r.top, r.right, r.bottom];
Rect _rect(List<Object?> l) => Rect.fromLTRB(
    (l[0] as num).toDouble(), (l[1] as num).toDouble(), (l[2] as num).toDouble(), (l[3] as num).toDouble());
List<double> _offsetJson(Offset o) => [o.dx, o.dy];
Offset _offset(List<Object?> l) => Offset((l[0] as num).toDouble(), (l[1] as num).toDouble());
