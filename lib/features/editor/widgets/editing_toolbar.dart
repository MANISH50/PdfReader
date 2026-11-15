import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../core/commands/undo_stack.dart';
import '../annotation_controller.dart';
import '../editor_tools.dart';
import '../../../ui/design_system/tokens.dart';

/// Horizontal annotation toolbar: tools, colour, stroke/font size, delete
/// selected, undo / redo (bound to [UndoStack]).
class EditingToolbar extends StatelessWidget {
  const EditingToolbar({
    super.key,
    required this.tool,
    required this.controller,
    this.tools = const [
      EditorTool.none,
      EditorTool.select,
      EditorTool.highlight,
      EditorTool.underline,
      EditorTool.strikeout,
      EditorTool.ink,
      EditorTool.note,
      EditorTool.textBox,
      EditorTool.rectangle,
      EditorTool.ellipse,
      EditorTool.line,
      EditorTool.arrow,
      EditorTool.signature,
    ],
    this.onSignatureTool,
  });

  final EditorToolState tool;
  final AnnotationController controller;
  final List<EditorTool> tools;

  /// Called when the signature tool is chosen (e.g. to pick a signature).
  final Future<void> Function()? onSignatureTool;

  UndoStack get undo => controller.undoStack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([tool, controller, undo]),
      builder: (context, _) {
        final current = tool.tool;
        final selected = controller.selected;
        return Material(
          color: scheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: kMinTouchTarget + Space.sm,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                children: [
                  IconButton(
                    key: const ValueKey('toolbar-undo'),
                    tooltip: undo.undoLabel == null ? 'Undo' : 'Undo ${undo.undoLabel}',
                    onPressed: undo.canUndo ? () => unawaited(undo.undo()) : null,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    key: const ValueKey('toolbar-redo'),
                    tooltip: undo.redoLabel == null ? 'Redo' : 'Redo ${undo.redoLabel}',
                    onPressed: undo.canRedo ? () => unawaited(undo.redo()) : null,
                    icon: const Icon(Icons.redo),
                  ),
                  if (selected != null && current == EditorTool.select)
                    IconButton(
                      key: const ValueKey('toolbar-delete'),
                      tooltip: 'Delete annotation',
                      onPressed: () => unawaited(controller.removeSelected()),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  _ColorButton(
                    color: selected?.color ?? tool.color,
                    onPicked: (c) {
                      final sel = controller.selected;
                      if (sel != null && current == EditorTool.select) {
                        unawaited(controller.recolor(sel.id, c));
                      } else {
                        tool.color = c;
                      }
                    },
                  ),
                  if (current == EditorTool.ink || current.isShape)
                    _SizeButton(
                      icon: Icons.line_weight,
                      tooltip: 'Stroke width',
                      value: tool.strokeWidth,
                      min: 0.5,
                      max: 12,
                      onChanged: (v) => tool.strokeWidth = v,
                    ),
                  if (current == EditorTool.textBox)
                    _SizeButton(
                      icon: Icons.format_size,
                      tooltip: 'Font size',
                      value: tool.fontSize,
                      min: 6,
                      max: 48,
                      onChanged: (v) => tool.fontSize = v,
                    ),
                  const VerticalDivider(width: Space.md, indent: Space.sm, endIndent: Space.sm),
                  for (final t in tools)
                    IconButton(
                      key: ValueKey('tool-${t.name}'),
                      tooltip: t.label,
                      isSelected: t == current,
                      style: IconButton.styleFrom(
                        backgroundColor: t == current ? scheme.secondaryContainer : null,
                      ),
                      onPressed: () async {
                        tool.tool = t;
                        if (t != EditorTool.select) controller.select(null);
                        if (t == EditorTool.signature) await onSignatureTool?.call();
                      },
                      icon: Icon(t.icon),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ColorButton extends StatelessWidget {
  const _ColorButton({required this.color, required this.onPicked});
  final Color color;
  final ValueChanged<Color> onPicked;

  @override
  Widget build(BuildContext context) => PopupMenuButton<Color>(
        tooltip: 'Colour',
        onSelected: onPicked,
        itemBuilder: (_) => [
          for (final c in kAnnotationPalette)
            PopupMenuItem(
              value: c,
              child: Row(children: [
                CircleAvatar(radius: 12, backgroundColor: c),
                const SizedBox(width: Space.sm),
                Text(_name(c)),
              ]),
            ),
        ],
        child: SizedBox(
          width: kMinTouchTarget,
          height: kMinTouchTarget,
          child: Center(
            child: CircleAvatar(
              radius: 12,
              backgroundColor: Theme.of(context).colorScheme.outline,
              child: CircleAvatar(radius: 10, backgroundColor: color),
            ),
          ),
        ),
      );

  static String _name(Color c) => switch (kAnnotationPalette.indexOf(c)) {
        0 => 'Yellow',
        1 => 'Green',
        2 => 'Blue',
        3 => 'Pink',
        4 => 'Red',
        5 => 'Dark blue',
        6 => 'Black',
        _ => 'Colour',
      };
}

class _SizeButton extends StatelessWidget {
  const _SizeButton({
    required this.icon,
    required this.tooltip,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  final IconData icon;
  final String tooltip;
  final double value, min, max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: () => unawaited(showModalBottomSheet<void>(
          context: context,
          builder: (c) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(tooltip, style: Theme.of(c).textTheme.titleMedium),
                _LiveSlider(initial: value, min: min, max: max, onChanged: onChanged),
              ]),
            ),
          ),
        )),
      );
}

class _LiveSlider extends StatefulWidget {
  const _LiveSlider({required this.initial, required this.min, required this.max, required this.onChanged});
  final double initial, min, max;
  final ValueChanged<double> onChanged;
  @override
  State<_LiveSlider> createState() => _LiveSliderState();
}

class _LiveSliderState extends State<_LiveSlider> {
  late double _v = widget.initial.clamp(widget.min, widget.max);
  @override
  Widget build(BuildContext context) => Slider(
        value: _v,
        min: widget.min,
        max: widget.max,
        label: _v.toStringAsFixed(1),
        divisions: ((widget.max - widget.min) * 2).round(),
        onChanged: (v) {
          setState(() => _v = v);
          widget.onChanged(v);
        },
      );
}
