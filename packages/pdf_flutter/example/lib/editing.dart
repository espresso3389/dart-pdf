import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';

/// The annotation tools the example app offers. Text markups (highlight,
/// underline, strike-out) are not modes — they act on the current text
/// selection directly from the toolbar.
enum EditTool { draw, rect, ellipse, text, note, stamp }

/// A full-page layer that captures the active tool's gestures in page
/// space and previews them before they become annotations.
///
/// Sits in the viewer's page overlay stack, so its recognizers are
/// innermost and win the arena over the viewer's selection drag.
class EditOverlay extends StatefulWidget {
  const EditOverlay({
    super.key,
    required this.tool,
    required this.pageIndex,
    required this.geometry,
    required this.color,
    required this.inkStrokes,
    required this.onRect,
    required this.onPoint,
    required this.onStroke,
  });

  final EditTool tool;
  final int pageIndex;
  final PdfPageGeometry geometry;
  final Color color;

  /// Committed but not yet applied ink strokes on this page (page coords).
  final List<List<(double, double)>> inkStrokes;

  final void Function(int pageIndex, PdfRect rect) onRect;
  final void Function(int pageIndex, double x, double y) onPoint;
  final void Function(int pageIndex, List<(double, double)> stroke) onStroke;

  @override
  State<EditOverlay> createState() => _EditOverlayState();
}

class _EditOverlayState extends State<EditOverlay> {
  Offset? _dragStart;
  Offset? _dragCurrent;
  List<(double, double)>? _activeStroke;

  bool get _isDrag => widget.tool != EditTool.draw && widget.tool != EditTool.note;

  void _panStart(DragStartDetails details) {
    if (widget.tool == EditTool.draw) {
      setState(() => _activeStroke = [
            widget.geometry.toPagePoint(details.localPosition),
          ]);
    } else if (_isDrag) {
      setState(() {
        _dragStart = details.localPosition;
        _dragCurrent = details.localPosition;
      });
    }
  }

  void _panUpdate(DragUpdateDetails details) {
    if (widget.tool == EditTool.draw) {
      setState(() =>
          _activeStroke?.add(widget.geometry.toPagePoint(details.localPosition)));
    } else if (_dragStart != null) {
      setState(() => _dragCurrent = details.localPosition);
    }
  }

  void _panEnd(DragEndDetails details) {
    final stroke = _activeStroke;
    final start = _dragStart;
    final current = _dragCurrent;
    setState(() {
      _activeStroke = null;
      _dragStart = null;
      _dragCurrent = null;
    });
    if (widget.tool == EditTool.draw && stroke != null && stroke.isNotEmpty) {
      widget.onStroke(widget.pageIndex, stroke);
    } else if (start != null && current != null) {
      final rect = Rect.fromPoints(start, current);
      if (rect.width < 4 || rect.height < 4) return; // accidental click
      widget.onRect(widget.pageIndex, widget.geometry.toPageRect(rect));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _panStart,
      onPanUpdate: _panUpdate,
      onPanEnd: _panEnd,
      onTapUp: widget.tool == EditTool.note
          ? (details) {
              final (x, y) = widget.geometry.toPagePoint(details.localPosition);
              widget.onPoint(widget.pageIndex, x, y);
            }
          : null,
      child: MouseRegion(
        cursor: widget.tool == EditTool.note
            ? SystemMouseCursors.click
            : SystemMouseCursors.precise,
        child: CustomPaint(
          painter: _EditPreviewPainter(
            tool: widget.tool,
            color: widget.color,
            geometry: widget.geometry,
            strokes: [
              ...widget.inkStrokes,
              if (_activeStroke != null) _activeStroke!,
            ],
            dragRect: _dragStart != null && _dragCurrent != null
                ? Rect.fromPoints(_dragStart!, _dragCurrent!)
                : null,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _EditPreviewPainter extends CustomPainter {
  _EditPreviewPainter({
    required this.tool,
    required this.color,
    required this.geometry,
    required this.strokes,
    required this.dragRect,
  });

  final EditTool tool;
  final Color color;
  final PdfPageGeometry geometry;
  final List<List<(double, double)>> strokes;
  final Rect? dragRect;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * geometry.scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final stroke in strokes) {
      final path = Path();
      for (var i = 0; i < stroke.length; i++) {
        final (x, y) = stroke[i];
        final p = geometry.toViewOffset(x, y);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      if (stroke.length == 1) {
        final p = geometry.toViewOffset(stroke.single.$1, stroke.single.$2);
        canvas.drawCircle(p, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
      } else {
        canvas.drawPath(path, paint);
      }
    }

    final rect = dragRect;
    if (rect != null) {
      switch (tool) {
        case EditTool.ellipse:
          canvas.drawOval(rect, paint);
        case EditTool.text || EditTool.stamp:
          canvas.drawRect(
              rect,
              paint
                ..strokeWidth = 1
                ..color = color.withValues(alpha: 0.7));
        default:
          canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_EditPreviewPainter oldDelegate) =>
      oldDelegate.strokes.length != strokes.length ||
      oldDelegate.dragRect != dragRect ||
      (strokes.isNotEmpty &&
          oldDelegate.strokes.isNotEmpty &&
          oldDelegate.strokes.last.length != strokes.last.length) ||
      oldDelegate.color != color ||
      oldDelegate.tool != tool;
}

/// The editing toolbar: text-markup actions for the current selection,
/// tool modes, a color palette, flatten, and save.
class EditBar extends StatelessWidget {
  const EditBar({
    super.key,
    required this.controller,
    required this.tool,
    required this.color,
    required this.hasPendingInk,
    required this.canSave,
    required this.onMarkup,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onFinishInk,
    required this.onCancelInk,
    required this.onFlatten,
    required this.onSave,
  });

  final PdfViewerController controller;
  final EditTool? tool;
  final Color color;
  final bool hasPendingInk;
  final bool canSave;
  final void Function(String kind) onMarkup;
  final ValueChanged<EditTool?> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onFinishInk;
  final VoidCallback onCancelInk;
  final VoidCallback onFlatten;
  final VoidCallback onSave;

  static const palette = [
    Color(0xFFE53935), // red
    Color(0xFFFFD100), // marker yellow
    Color(0xFF43A047), // green
    Color(0xFF1E88E5), // blue
    Color(0xFF000000), // black
  ];

  @override
  Widget build(BuildContext context) {
    Widget toolButton(EditTool value, IconData icon, String tooltip) =>
        IconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          isSelected: tool == value,
          onPressed: () => onToolChanged(tool == value ? null : value),
        );

    return BottomAppBar(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final enabled = controller.hasSelection;
              return Row(children: [
                IconButton(
                  icon: const Icon(Icons.border_color),
                  tooltip: 'Highlight selection',
                  onPressed: enabled ? () => onMarkup('highlight') : null,
                ),
                IconButton(
                  icon: const Icon(Icons.format_underlined),
                  tooltip: 'Underline selection',
                  onPressed: enabled ? () => onMarkup('underline') : null,
                ),
                IconButton(
                  icon: const Icon(Icons.format_strikethrough),
                  tooltip: 'Strike out selection',
                  onPressed: enabled ? () => onMarkup('strikeout') : null,
                ),
              ]);
            },
          ),
          const VerticalDivider(width: 16),
          toolButton(EditTool.draw, Icons.draw, 'Draw'),
          if (hasPendingInk) ...[
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Add ink annotation',
              onPressed: onFinishInk,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Discard drawing',
              onPressed: onCancelInk,
            ),
          ],
          toolButton(EditTool.rect, Icons.rectangle_outlined, 'Rectangle'),
          toolButton(EditTool.ellipse, Icons.circle_outlined, 'Ellipse'),
          toolButton(EditTool.text, Icons.text_fields, 'Text box'),
          toolButton(EditTool.note, Icons.sticky_note_2_outlined, 'Note'),
          toolButton(EditTool.stamp, Icons.approval, 'Stamp'),
          const VerticalDivider(width: 16),
          for (final c in palette)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                onTap: () => onColorChanged(c),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color == c
                          ? Theme.of(context).colorScheme.primary
                          : Colors.black26,
                      width: color == c ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
          const VerticalDivider(width: 16),
          IconButton(
            icon: const Icon(Icons.layers),
            tooltip: 'Flatten annotations into the page',
            onPressed: onFlatten,
          ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Save annotated copy…',
            onPressed: canSave ? onSave : null,
          ),
        ]),
      ),
    );
  }
}

/// A one-field dialog used by the text, note, and stamp tools.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final field = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        maxLines: title.contains('note') ? 4 : 1,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(field.text),
          child: const Text('Add'),
        ),
      ],
    ),
  );
}
