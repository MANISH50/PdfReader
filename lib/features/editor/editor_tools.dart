import 'package:material_ui/material_ui.dart';

import '../../core/models/annotation.dart';

/// Annotation tools. [none] lets all gestures through to the viewer.
enum EditorTool {
  none,
  select,
  highlight,
  underline,
  strikeout,
  note,
  ink,
  rectangle,
  ellipse,
  line,
  arrow,
  textBox,
  signature;

  bool get isMarkup => this == highlight || this == underline || this == strikeout;
  bool get isShape => this == rectangle || this == ellipse || this == line || this == arrow;

  MarkupKind? get markupKind => switch (this) {
        highlight => MarkupKind.highlight,
        underline => MarkupKind.underline,
        strikeout => MarkupKind.strikeout,
        _ => null,
      };

  ShapeKind? get shapeKind => switch (this) {
        rectangle => ShapeKind.rectangle,
        ellipse => ShapeKind.ellipse,
        line => ShapeKind.line,
        arrow => ShapeKind.arrow,
        _ => null,
      };

  String get label => switch (this) {
        none => 'Read',
        select => 'Select',
        highlight => 'Highlight',
        underline => 'Underline',
        strikeout => 'Strike-through',
        note => 'Note',
        ink => 'Pen',
        rectangle => 'Rectangle',
        ellipse => 'Ellipse',
        line => 'Line',
        arrow => 'Arrow',
        textBox => 'Text box',
        signature => 'Signature',
      };

  IconData get icon => switch (this) {
        none => Icons.pan_tool_outlined,
        select => Icons.near_me_outlined,
        highlight => Icons.border_color_outlined,
        underline => Icons.format_underlined,
        strikeout => Icons.format_strikethrough,
        note => Icons.sticky_note_2_outlined,
        ink => Icons.gesture,
        rectangle => Icons.crop_square,
        ellipse => Icons.circle_outlined,
        line => Icons.horizontal_rule,
        arrow => Icons.north_east,
        textBox => Icons.text_fields,
        signature => Icons.draw_outlined,
      };
}

/// Palette offered by the toolbar.
const List<Color> kAnnotationPalette = [
  Color(0xFFFFD400), // yellow
  Color(0xFF7CDA4E), // green
  Color(0xFF4FC3F7), // blue
  Color(0xFFFF7AB6), // pink
  Color(0xFFE53935), // red
  Color(0xFF1E40AF), // dark blue
  Color(0xFF000000), // black
];

/// Current tool, colour and sizes. Shared by the toolbar and every
/// [AnnotationLayer] of a document.
class EditorToolState extends ChangeNotifier {
  EditorTool _tool = EditorTool.none;
  Color _color = kAnnotationPalette.first;
  Color _inkColor = const Color(0xFFE53935);
  double _strokeWidth = 2;
  double _fontSize = 14;
  String? _signatureId;

  EditorTool get tool => _tool;
  set tool(EditorTool t) {
    if (t == _tool) return;
    _tool = t;
    notifyListeners();
  }

  /// Colour used for the current tool (markup tools default to yellow,
  /// drawing tools to red).
  Color get color => _tool.isMarkup || _tool == EditorTool.note ? _color : _inkColor;
  set color(Color c) {
    if (_tool.isMarkup || _tool == EditorTool.note) {
      _color = c;
    } else {
      _inkColor = c;
    }
    notifyListeners();
  }

  double get strokeWidth => _strokeWidth;
  set strokeWidth(double v) {
    _strokeWidth = v.clamp(0.5, 24);
    notifyListeners();
  }

  double get fontSize => _fontSize;
  set fontSize(double v) {
    _fontSize = v.clamp(6, 72);
    notifyListeners();
  }

  /// Signature placed by the next tap with [EditorTool.signature].
  String? get signatureId => _signatureId;
  set signatureId(String? id) {
    _signatureId = id;
    notifyListeners();
  }
}
