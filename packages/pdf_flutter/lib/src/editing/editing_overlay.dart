import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import '../page_geometry.dart';
import 'editing_controller.dart';
import 'text_prompt.dart';

/// One page's editing layer: captures the armed tool's gestures in page
/// space, previews them, and commits them through the controller.
///
/// Instantiated by [PdfViewer] for every page while
/// [PdfEditingController.tool] is armed. It sits innermost in the page
/// overlay stack, so its recognizers win the arena over the viewer's
/// text-selection drag.
class EditingPageOverlay extends StatefulWidget {
  const EditingPageOverlay({
    super.key,
    required this.controller,
    required this.pageIndex,
    required this.geometry,
    required this.textPrompt,
  });

  final PdfEditingController controller;
  final int pageIndex;
  final PdfPageGeometry geometry;
  final PdfTextPrompt textPrompt;

  @override
  State<EditingPageOverlay> createState() => _EditingPageOverlayState();
}

/// Which sides of the selection a resize handle moves: -1 left/top edge,
/// +1 right/bottom edge, 0 leaves that axis alone. (View space, y down.)
typedef _Handle = ({int dx, int dy});

const List<_Handle> _handles = [
  (dx: -1, dy: -1), (dx: 0, dy: -1), (dx: 1, dy: -1),
  (dx: -1, dy: 0), (dx: 1, dy: 0),
  (dx: -1, dy: 1), (dx: 0, dy: 1), (dx: 1, dy: 1),
];

const double _handleSize = 8;
const double _handleHitRadius = 12;
const double _minSizeView = 12;

class _EditingPageOverlayState extends State<EditingPageOverlay> {
  // shape/text/stamp drag
  Offset? _dragStart;
  Offset? _dragCurrent;

  // ink
  List<(double, double)>? _activeStroke;

  // select-tool drags
  Offset? _moveStart;
  Offset? _moveCurrent;
  _Handle? _resizeHandle;
  Rect? _resizeRect;

  MouseCursor _cursor = MouseCursor.defer;

  PdfEditingController get _controller => widget.controller;
  PdfPageGeometry get _geometry => widget.geometry;
  PdfEditTool get _tool => _controller.tool!;

  /// The selected annotation's view rect when it lives on this page.
  Rect? get _selectedViewRect {
    if (_controller.selectedPage != widget.pageIndex) return null;
    final annotation = _controller.selectedAnnotation;
    return annotation == null ? null : _geometry.toViewRect(annotation.rect);
  }

  Offset _handleCenter(Rect rect, _Handle handle) => Offset(
        rect.center.dx + handle.dx * rect.width / 2,
        rect.center.dy + handle.dy * rect.height / 2,
      );

  _Handle? _handleAt(Rect rect, Offset position) {
    if (!_controller.canResizeSelected) return null;
    for (final handle in _handles) {
      if ((position - _handleCenter(rect, handle)).distance <=
          _handleHitRadius) {
        return handle;
      }
    }
    return null;
  }

  Rect _resizedRect(Rect from, _Handle handle, Offset delta) {
    var left = from.left, top = from.top;
    var right = from.right, bottom = from.bottom;
    if (handle.dx < 0) left += delta.dx;
    if (handle.dx > 0) right += delta.dx;
    if (handle.dy < 0) top += delta.dy;
    if (handle.dy > 0) bottom += delta.dy;
    // never collapse or invert: the dragged side stops at the minimum
    if (right - left < _minSizeView) {
      if (handle.dx < 0) {
        left = right - _minSizeView;
      } else {
        right = left + _minSizeView;
      }
    }
    if (bottom - top < _minSizeView) {
      if (handle.dy < 0) {
        top = bottom - _minSizeView;
      } else {
        bottom = top + _minSizeView;
      }
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _panStart(DragStartDetails details) {
    final position = details.localPosition;
    switch (_tool) {
      case PdfEditTool.select:
        final selected = _selectedViewRect;
        if (selected == null) return;
        final handle = _handleAt(selected, position);
        if (handle != null) {
          setState(() {
            _resizeHandle = handle;
            _resizeRect = selected;
            _moveStart = position;
            _moveCurrent = position;
          });
        } else if (selected.contains(position)) {
          setState(() {
            _moveStart = position;
            _moveCurrent = position;
          });
        }
      case PdfEditTool.ink:
        setState(
            () => _activeStroke = [_geometry.toPagePoint(position)]);
      case PdfEditTool.rectangle ||
            PdfEditTool.ellipse ||
            PdfEditTool.freeText ||
            PdfEditTool.stamp:
        setState(() {
          _dragStart = position;
          _dragCurrent = position;
        });
      case PdfEditTool.note:
        break; // placed by tap
    }
  }

  void _panUpdate(DragUpdateDetails details) {
    final position = details.localPosition;
    if (_resizeHandle != null) {
      setState(() {
        _moveCurrent = position;
        _resizeRect = _resizedRect(
            _selectedViewRect!, _resizeHandle!, position - _moveStart!);
      });
    } else if (_moveStart != null) {
      setState(() => _moveCurrent = position);
    } else if (_activeStroke != null) {
      setState(() => _activeStroke!.add(_geometry.toPagePoint(position)));
    } else if (_dragStart != null) {
      setState(() => _dragCurrent = position);
    }
  }

  void _panEnd(DragEndDetails details) {
    final stroke = _activeStroke;
    final dragStart = _dragStart;
    final dragCurrent = _dragCurrent;
    final moveStart = _moveStart;
    final moveCurrent = _moveCurrent;
    final resizeRect = _resizeHandle != null ? _resizeRect : null;
    setState(() {
      _activeStroke = null;
      _dragStart = null;
      _dragCurrent = null;
      _moveStart = null;
      _moveCurrent = null;
      _resizeHandle = null;
      _resizeRect = null;
    });

    if (resizeRect != null) {
      _controller.resizeSelected(_geometry.toPageRect(resizeRect));
    } else if (moveStart != null && moveCurrent != null) {
      if ((moveCurrent - moveStart).distance < 2) return; // a click
      // mapping both endpoints keeps the delta correct on rotated pages
      final (x0, y0) = _geometry.toPagePoint(moveStart);
      final (x1, y1) = _geometry.toPagePoint(moveCurrent);
      _controller.moveSelected(x1 - x0, y1 - y0);
    } else if (stroke != null && stroke.isNotEmpty) {
      _controller.addInkStroke(widget.pageIndex, stroke);
    } else if (dragStart != null && dragCurrent != null) {
      final viewRect = Rect.fromPoints(dragStart, dragCurrent);
      if (viewRect.width < 4 || viewRect.height < 4) return; // a click
      _commitRect(_geometry.toPageRect(viewRect));
    }
  }

  Future<void> _commitRect(PdfRect rect) async {
    switch (_tool) {
      case PdfEditTool.rectangle:
        _controller.addRectangle(widget.pageIndex, rect);
      case PdfEditTool.ellipse:
        _controller.addEllipse(widget.pageIndex, rect);
      case PdfEditTool.freeText:
        final text =
            await widget.textPrompt(context, title: 'Text', multiline: true);
        if (text == null || text.isEmpty) return;
        _controller.addFreeText(widget.pageIndex, rect, text);
      case PdfEditTool.stamp:
        final text = await widget.textPrompt(context,
            title: 'Stamp text', initial: 'APPROVED');
        if (text == null || text.isEmpty) return;
        _controller.addStamp(widget.pageIndex, rect, text);
      default:
        break;
    }
  }

  Future<void> _onTapUp(TapUpDetails details) async {
    final (x, y) = _geometry.toPagePoint(details.localPosition);
    switch (_tool) {
      case PdfEditTool.select:
        _controller.selectAnnotationAt(widget.pageIndex, x, y);
      case PdfEditTool.note:
        final text =
            await widget.textPrompt(context, title: 'Note', multiline: true);
        if (text == null || text.isEmpty) return;
        _controller.addNote(widget.pageIndex, x, y, text);
      default:
        break;
    }
  }

  void _onHover(PointerHoverEvent event) {
    final MouseCursor cursor;
    if (_tool == PdfEditTool.select) {
      final selected = _selectedViewRect;
      final handle =
          selected == null ? null : _handleAt(selected, event.localPosition);
      if (handle != null) {
        cursor = switch ((handle.dx, handle.dy)) {
          (0, _) => SystemMouseCursors.resizeUpDown,
          (_, 0) => SystemMouseCursors.resizeLeftRight,
          (-1, -1) || (1, 1) => SystemMouseCursors.resizeUpLeftDownRight,
          _ => SystemMouseCursors.resizeUpRightDownLeft,
        };
      } else if (selected != null &&
          selected.contains(event.localPosition)) {
        cursor = SystemMouseCursors.move;
      } else {
        cursor = SystemMouseCursors.basic;
      }
    } else if (_tool == PdfEditTool.note) {
      cursor = SystemMouseCursors.click;
    } else {
      cursor = SystemMouseCursors.precise;
    }
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedViewRect;
    final moveDelta = _resizeHandle == null &&
            _moveStart != null &&
            _moveCurrent != null
        ? _moveCurrent! - _moveStart!
        : Offset.zero;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // anchor drags at the press point, not where the recognizer won the
      // arena — a shape should start exactly where the pointer went down
      dragStartBehavior: DragStartBehavior.down,
      onPanStart: _panStart,
      onPanUpdate: _panUpdate,
      onPanEnd: _panEnd,
      onTapUp: _onTapUp,
      child: MouseRegion(
        cursor: _cursor,
        onHover: _onHover,
        child: CustomPaint(
          painter: _EditingPreviewPainter(
            tool: _tool,
            color: _controller.color,
            strokeWidth: _controller.strokeWidth * _geometry.scale,
            geometry: _geometry,
            strokes: [
              ..._controller.strokesOn(widget.pageIndex),
              if (_activeStroke != null) _activeStroke!,
            ],
            dragRect: _dragStart != null && _dragCurrent != null
                ? Rect.fromPoints(_dragStart!, _dragCurrent!)
                : null,
            selectionRect: _resizeHandle != null
                ? _resizeRect
                : selected?.shift(moveDelta),
            showHandles: selected != null &&
                _controller.canResizeSelected &&
                _moveStart == null,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _EditingPreviewPainter extends CustomPainter {
  _EditingPreviewPainter({
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.geometry,
    required this.strokes,
    required this.dragRect,
    required this.selectionRect,
    required this.showHandles,
  });

  final PdfEditTool tool;
  final Color color;
  final double strokeWidth;
  final PdfPageGeometry geometry;
  final List<List<(double, double)>> strokes;
  final Rect? dragRect;
  final Rect? selectionRect;
  final bool showHandles;

  static const _chrome = Color(0xFF1E88E5);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final stroke in strokes) {
      if (stroke.length == 1) {
        final p = geometry.toViewOffset(stroke.single.$1, stroke.single.$2);
        canvas.drawCircle(p, strokeWidth / 2,
            Paint()..color = color);
        continue;
      }
      final path = Path();
      for (var i = 0; i < stroke.length; i++) {
        final (x, y) = stroke[i];
        final p = geometry.toViewOffset(x, y);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }

    final rect = dragRect;
    if (rect != null) {
      switch (tool) {
        case PdfEditTool.ellipse:
          canvas.drawOval(rect, paint);
        case PdfEditTool.freeText || PdfEditTool.stamp:
          canvas.drawRect(
              rect,
              Paint()
                ..color = color.withValues(alpha: 0.7)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1);
        default:
          canvas.drawRect(rect, paint);
      }
    }

    final selection = selectionRect;
    if (selection != null) {
      final box = selection.inflate(2);
      canvas.drawRect(box, Paint()..color = const Color(0x1A1E88E5));
      canvas.drawRect(
          box,
          Paint()
            ..color = _chrome
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
      if (showHandles) {
        final fill = Paint()..color = const Color(0xFFFFFFFF);
        final stroke = Paint()
          ..color = _chrome
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        for (final handle in _handles) {
          final center = Offset(
            box.center.dx + handle.dx * box.width / 2,
            box.center.dy + handle.dy * box.height / 2,
          );
          final knob =
              Rect.fromCircle(center: center, radius: _handleSize / 2);
          canvas.drawRect(knob, fill);
          canvas.drawRect(knob, stroke);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_EditingPreviewPainter oldDelegate) =>
      oldDelegate.tool != tool ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.dragRect != dragRect ||
      oldDelegate.selectionRect != selectionRect ||
      oldDelegate.showHandles != showHandles ||
      oldDelegate.strokes.length != strokes.length ||
      (strokes.isNotEmpty &&
          oldDelegate.strokes.isNotEmpty &&
          oldDelegate.strokes.last.length != strokes.last.length);
}
