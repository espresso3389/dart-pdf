import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import '../page_geometry.dart';
import '../renderer.dart';
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
  (dx: -1, dy: -1),
  (dx: 0, dy: -1),
  (dx: 1, dy: -1),
  (dx: -1, dy: 0),
  (dx: 1, dy: 0),
  (dx: -1, dy: 1),
  (dx: 0, dy: 1),
  (dx: 1, dy: 1),
];

const double _handleSize = 8;
const double _handleHitRadius = 12;
const double _minSizeView = 12;

/// How far the rotation knob floats above the selection's top edge.
const double _rotateHandleDistance = 22;

/// Rotation drags snap to 45° multiples when within this margin.
const double _rotateSnapRadians = 3 * math.pi / 180;

class _EditingPageOverlayState extends State<EditingPageOverlay> {
  // shape/text/stamp drag
  Offset? _dragStart;
  Offset? _dragCurrent;

  // eyedropper: one page raster serves every preview sample
  PdfPageColorSampler? _sampler;
  PdfDocument? _samplerDocument;
  Future<PdfPageColorSampler>? _samplerFuture;
  Offset? _pickPosition;
  Color? _pickPreview;

  // ink
  List<(double, double)>? _activeStroke;
  List<double>? _activeStrokePressures;

  /// The latest normalized pressure of the pointer being tracked, or null
  /// for devices that don't report pressure (finger, mouse).
  double? _pointerPressure;

  // select-tool drags
  Offset? _moveStart;
  Offset? _moveCurrent;
  _Handle? _resizeHandle;
  Rect? _resizeRect;

  // rotate drag: the pointer's start angle about the selection center,
  // and the current delta (view space, clockwise positive — y is down)
  double? _rotateStartAngle;
  double _rotateDelta = 0;

  // live drag preview: the selected annotation's appearance, rendered
  // once per (revision, selection) and drawn stretched while dragging
  ui.Picture? _ghost;
  (PdfDocument, int, int)? _ghostKey;

  MouseCursor _cursor = MouseCursor.defer;

  PdfEditingController get _controller => widget.controller;
  PdfPageGeometry get _geometry => widget.geometry;

  /// Null only while the eyedropper is armed without a tool.
  PdfEditTool? get _tool => _controller.tool;

  static double? _normalizedPressure(PointerEvent event) =>
      event.pressureMax > event.pressureMin
          ? ((event.pressure - event.pressureMin) /
                  (event.pressureMax - event.pressureMin))
              .clamp(0.0, 1.0)
          : null;

  /// Raw-pointer bookkeeping the pan callbacks can't see: the pressure
  /// stream, and stylus detection for palm rejection.
  void _onPointerDown(PointerDownEvent event) {
    _pointerPressure = _normalizedPressure(event);
    if (_controller.isPickingColor) {
      _updatePickPreview(event.localPosition);
      return;
    }
    if (_tool == PdfEditTool.ink &&
        _controller.fingerDrawsInk &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      // an Apple Pencil (or other stylus) is in play: from now on the
      // pen draws and fingers scroll, until the user toggles it back
      _controller.fingerDrawsInk = false;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final pressure = _normalizedPressure(event);
    if (pressure != null) _pointerPressure = pressure;
    if (_controller.isPickingColor) _updatePickPreview(event.localPosition);
  }

  /// The selected annotation's view rect when it lives on this page.
  Rect? get _selectedViewRect {
    if (_controller.selectedPage != widget.pageIndex) return null;
    final annotation = _controller.selectedAnnotation;
    return annotation == null ? null : _geometry.toViewRect(annotation.rect);
  }

  /// The selected content element's view rect when it lives on this page.
  Rect? get _selectedElementViewRect {
    if (_controller.selectedElementPage != widget.pageIndex) return null;
    final bounds = _controller.selectedElement?.bounds;
    return bounds == null ? null : _geometry.toViewRect(bounds);
  }

  /// Keeps [_ghost] current: the selected annotation's appearance as a
  /// page-space picture, so a move/resize drag can show the artwork at
  /// its new place instead of just the chrome. Re-renders only when the
  /// revision or the selection changes; called from [build] so the
  /// picture is usually ready before a drag starts.
  void _ensureGhost() {
    final slot = _controller.selectedAnnotationSlot;
    final document = _controller.document;
    if (slot == null || slot.$1 != widget.pageIndex) {
      _ghost?.dispose();
      _ghost = null;
      _ghostKey = null;
      return;
    }
    final key = (document, slot.$1, slot.$2);
    if (key == _ghostKey) return;
    _ghostKey = key;
    _ghost?.dispose();
    _ghost = null;
    final annotation = _controller.selectedAnnotation;
    if (annotation == null) return;
    unawaited(PdfPageRenderer.renderAnnotationPicture(
            document.page(widget.pageIndex), annotation)
        .then((picture) {
      if (!mounted || _ghostKey != key) {
        picture?.dispose();
        return;
      }
      setState(() => _ghost = picture);
    }));
  }

  @override
  void dispose() {
    _ghost?.dispose();
    super.dispose();
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

  Offset _rotateHandleCenter(Rect rect) =>
      Offset(rect.center.dx, rect.top - _rotateHandleDistance);

  /// Resize handles get first claim (the top-center knob sits close),
  /// so this is only consulted after [_handleAt] misses.
  bool _hitsRotateHandle(Rect rect, Offset position) =>
      _controller.canRotateSelected &&
      (position - _rotateHandleCenter(rect)).distance <= _handleHitRadius;

  /// The drag's rotation delta for the pointer at [position]: the angle
  /// swept about the selection center, snapped near 45° multiples.
  double _rotationDelta(Rect selected, Offset position) {
    var delta =
        (position - selected.center).direction - _rotateStartAngle!;
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    while (delta <= -math.pi) {
      delta += 2 * math.pi;
    }
    final snapped = (delta / (math.pi / 4)).round() * (math.pi / 4);
    return (delta - snapped).abs() <= _rotateSnapRadians ? snapped : delta;
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
      case null:
        break; // eyedropper only — taps, no drags
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
        } else if (_hitsRotateHandle(selected, position)) {
          setState(() {
            _rotateStartAngle = (position - selected.center).direction;
            _rotateDelta = 0;
          });
        } else if (selected.contains(position)) {
          setState(() {
            _moveStart = position;
            _moveCurrent = position;
          });
        }
      case PdfEditTool.ink:
        final pressure = _pointerPressure;
        setState(() {
          _activeStroke = [_geometry.toPagePoint(position)];
          // the first event decides: a pressure device varies the whole
          // stroke, anything else stays uniform
          _activeStrokePressures = pressure == null ? null : [pressure];
        });
      case PdfEditTool.rectangle ||
            PdfEditTool.ellipse ||
            PdfEditTool.freeText ||
            PdfEditTool.stamp:
        setState(() {
          _dragStart = position;
          _dragCurrent = position;
        });
      case PdfEditTool.note || PdfEditTool.content || PdfEditTool.signature:
        break; // driven by taps
    }
  }

  void _panUpdate(DragUpdateDetails details) {
    final position = details.localPosition;
    if (_rotateStartAngle != null) {
      final selected = _selectedViewRect;
      if (selected == null) return;
      setState(() => _rotateDelta = _rotationDelta(selected, position));
    } else if (_resizeHandle != null) {
      setState(() {
        _moveCurrent = position;
        _resizeRect = _resizedRect(
            _selectedViewRect!, _resizeHandle!, position - _moveStart!);
      });
    } else if (_moveStart != null) {
      setState(() => _moveCurrent = position);
    } else if (_activeStroke != null) {
      setState(() {
        _activeStroke!.add(_geometry.toPagePoint(position));
        _activeStrokePressures
            ?.add(_pointerPressure ?? _activeStrokePressures!.last);
      });
    } else if (_dragStart != null) {
      setState(() => _dragCurrent = position);
    }
  }

  void _panEnd(DragEndDetails details) {
    final stroke = _activeStroke;
    final strokePressures = _activeStrokePressures;
    final dragStart = _dragStart;
    final dragCurrent = _dragCurrent;
    final moveStart = _moveStart;
    final moveCurrent = _moveCurrent;
    final resizeRect = _resizeHandle != null ? _resizeRect : null;
    final rotating = _rotateStartAngle != null;
    final rotateDelta = _rotateDelta;
    setState(() {
      _activeStroke = null;
      _activeStrokePressures = null;
      _dragStart = null;
      _dragCurrent = null;
      _moveStart = null;
      _moveCurrent = null;
      _resizeHandle = null;
      _resizeRect = null;
      _rotateStartAngle = null;
      _rotateDelta = 0;
    });

    if (rotating) {
      // view-space clockwise (y down) is page-space clockwise, and PDF
      // rotation is counterclockwise-positive — hence the sign flip
      _controller.rotateSelected(-rotateDelta * 180 / math.pi);
    } else if (resizeRect != null) {
      _controller.resizeSelected(_geometry.toPageRect(resizeRect));
    } else if (moveStart != null && moveCurrent != null) {
      if ((moveCurrent - moveStart).distance < 2) return; // a click
      // mapping both endpoints keeps the delta correct on rotated pages
      final (x0, y0) = _geometry.toPagePoint(moveStart);
      final (x1, y1) = _geometry.toPagePoint(moveCurrent);
      _controller.moveSelected(x1 - x0, y1 - y0);
    } else if (stroke != null && stroke.isNotEmpty) {
      _controller.addInkStroke(widget.pageIndex, stroke,
          pressures: strokePressures);
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
        final stamp = _controller.activeStamp;
        if (stamp != null) {
          _controller.addStamp(widget.pageIndex, rect, stamp.text,
              color: stamp.color);
          return;
        }
        final text = await widget.textPrompt(context,
            title: 'Stamp text', initial: 'APPROVED');
        if (text == null || text.isEmpty) return;
        _controller.addStamp(widget.pageIndex, rect, text);
      default:
        break;
    }
  }

  /// Rasterizes this page once for the eyedropper, keyed on document
  /// identity (it changes every revision). The page raster at scale 1
  /// shares the view's orientation, so view → raster is just the
  /// geometry scale.
  Future<PdfPageColorSampler> _ensureSampler() {
    final document = _controller.document;
    if (!identical(document, _samplerDocument)) {
      _samplerDocument = document;
      _sampler = null;
      _samplerFuture =
          PdfPageColorSampler.of(document.page(widget.pageIndex)).then((s) {
        // resolve the preview that was waiting on the raster
        if (mounted && identical(_samplerDocument, document)) {
          setState(() {
            _sampler = s;
            final position = _pickPosition;
            if (position != null) {
              _pickPreview = s.colorAt(position / _geometry.scale);
            }
          });
        }
        return s;
      });
    }
    return _samplerFuture!;
  }

  void _updatePickPreview(Offset position) {
    unawaited(_ensureSampler());
    setState(() {
      _pickPosition = position;
      _pickPreview = _sampler?.colorAt(position / _geometry.scale);
    });
  }

  /// Releasing the pointer picks the previewed color — so both a plain
  /// tap and press-drag-release (watching the preview) work. A raw
  /// listener, so it fires regardless of the gesture arena.
  Future<void> _onPointerUp(PointerUpEvent event) async {
    if (!_controller.isPickingColor) return;
    final document = _controller.document;
    final sampler = await _ensureSampler();
    if (!mounted || !identical(document, _controller.document)) return;
    setState(() {
      _pickPosition = null;
      _pickPreview = null;
    });
    final color = sampler.colorAt(event.localPosition / _geometry.scale);
    if (color != null) _controller.finishColorPick(color);
  }

  Future<void> _onTapUp(TapUpDetails details) async {
    // the eyedropper commits from the raw pointer-up instead
    if (_controller.isPickingColor) return;
    final (x, y) = _geometry.toPagePoint(details.localPosition);
    switch (_tool) {
      case null:
        break;
      case PdfEditTool.select:
        _controller.selectAnnotationAt(widget.pageIndex, x, y);
      case PdfEditTool.content:
        _controller.selectElementAt(widget.pageIndex, x, y);
      case PdfEditTool.note:
        final text =
            await widget.textPrompt(context, title: 'Note', multiline: true);
        if (text == null || text.isEmpty) return;
        _controller.addNote(widget.pageIndex, x, y, text);
      case PdfEditTool.signature:
        _controller.placeSignature(widget.pageIndex, x, y);
      case PdfEditTool.stamp:
        // no-op without an active custom stamp (the classic flow drags)
        _controller.placeStamp(widget.pageIndex, x, y);
      default:
        break;
    }
  }

  void _onHover(PointerHoverEvent event) {
    final MouseCursor cursor;
    if (_controller.isPickingColor) {
      _updatePickPreview(event.localPosition);
      cursor = SystemMouseCursors.precise;
    } else if (_tool == PdfEditTool.select) {
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
          _hitsRotateHandle(selected, event.localPosition)) {
        cursor = SystemMouseCursors.grab;
      } else if (selected != null && selected.contains(event.localPosition)) {
        cursor = SystemMouseCursors.move;
      } else {
        cursor = SystemMouseCursors.basic;
      }
    } else if (_tool == PdfEditTool.note) {
      cursor = SystemMouseCursors.click;
    } else if (_tool == PdfEditTool.content) {
      final (x, y) = _geometry.toPagePoint(event.localPosition);
      cursor =
          _controller.elementsOn(widget.pageIndex).elementsAt(x, y).isNotEmpty
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic;
    } else {
      cursor = SystemMouseCursors.precise;
    }
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  @override
  Widget build(BuildContext context) {
    _ensureGhost();
    final selected = _selectedViewRect;
    final moveDelta =
        _resizeHandle == null && _moveStart != null && _moveCurrent != null
            ? _moveCurrent! - _moveStart!
            : Offset.zero;
    final rotating = _rotateStartAngle != null;
    final dragging =
        _resizeHandle != null || moveDelta != Offset.zero || rotating;
    // warm the eyedropper's raster so the first preview is instant-ish
    if (_controller.isPickingColor) unawaited(_ensureSampler());
    final preview = _controller.isPickingColor ? _pickPosition : null;
    return Listener(
      // raw events carry what pan callbacks drop: pressure and the
      // device kind (for Apple Pencil palm rejection); pointer-up is
      // also the eyedropper's commit
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // with finger drawing off, touch falls through to the scroll
        // view and only pen-like devices reach the ink recognizers
        supportedDevices:
            _tool == PdfEditTool.ink && !_controller.fingerDrawsInk
                ? const {
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                  }
                : null,
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
          onExit: (_) {
            if (_pickPosition == null) return;
            setState(() {
              _pickPosition = null;
              _pickPreview = null;
            });
          },
          child: Stack(children: [
            Positioned.fill(
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
                  pressures: [
                    ..._controller.strokePressuresOn(widget.pageIndex),
                    if (_activeStroke != null) _activeStrokePressures,
                  ],
                  dragRect: _dragStart != null && _dragCurrent != null
                      ? Rect.fromPoints(_dragStart!, _dragCurrent!)
                      : null,
                  selectionRect: _resizeHandle != null
                      ? _resizeRect
                      : selected?.shift(moveDelta),
                  ghost: _ghost,
                  ghostFrom: selected,
                  dragging: dragging,
                  rotation: rotating ? _rotateDelta : 0,
                  showHandles: selected != null &&
                      _controller.canResizeSelected &&
                      _moveStart == null,
                  showRotateHandle: selected != null &&
                      _controller.canRotateSelected &&
                      _moveStart == null,
                  elementRect: _selectedElementViewRect,
                ),
                size: Size.infinite,
              ),
            ),
            if (preview != null)
              Positioned(
                left: preview.dx + 14,
                top: preview.dy - 38,
                child: IgnorePointer(
                  child: _EyedropperChip(color: _pickPreview),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The eyedropper's floating preview: the color under the pointer and
/// its hex value, riding beside the cursor.
class _EyedropperChip extends StatelessWidget {
  const _EyedropperChip({required this.color});

  /// Null while the page raster is still being built (or off the page).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color ?? Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black26),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            color == null
                ? '…'
                : '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ]),
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
    required this.pressures,
    required this.dragRect,
    required this.selectionRect,
    required this.ghost,
    required this.ghostFrom,
    required this.dragging,
    required this.rotation,
    required this.showHandles,
    required this.showRotateHandle,
    required this.elementRect,
  });

  final PdfEditTool? tool;
  final Color color;
  final double strokeWidth;
  final PdfPageGeometry geometry;
  final List<List<(double, double)>> strokes;

  /// Parallels [strokes]: per-point normalized pressures, or null for a
  /// uniform-width stroke.
  final List<List<double>?> pressures;

  final Rect? dragRect;
  final Rect? selectionRect;

  /// The selected annotation's appearance in page raster space, and its
  /// resting view rect — drawn stretched onto [selectionRect] while
  /// [dragging], so the user sees the move/resize result live.
  final ui.Picture? ghost;
  final Rect? ghostFrom;
  final bool dragging;

  /// A rotate drag's current sweep (view radians, clockwise positive):
  /// the ghost and the chrome spin by it about the selection center.
  final double rotation;

  final bool showHandles;
  final bool showRotateHandle;

  /// The selected content element's box — orange, to read as "page
  /// content", distinct from the blue annotation chrome.
  final Rect? elementRect;

  static const _chrome = Color(0xFF1E88E5);
  static const _elementChrome = Color(0xFFFB8C00);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var s = 0; s < strokes.length; s++) {
      final stroke = strokes[s];
      final pressure = s < pressures.length ? pressures[s] : null;
      if (stroke.length == 1) {
        final p = geometry.toViewOffset(stroke.single.$1, stroke.single.$2);
        final width = pressure == null
            ? strokeWidth
            : pdfInkStrokeWidth(strokeWidth, pressure.first);
        canvas.drawCircle(p, width / 2, Paint()..color = color);
        continue;
      }
      // the same Catmull-Rom smoothing the committed appearance uses
      final controls = pdfInkCurveControls(stroke);
      if (pressure != null) {
        // matches the committed appearance: a stroked spline segment per
        // point pair at its own pressure-mapped width, round caps as the
        // seams
        final segment = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < stroke.length - 1; i++) {
          final (xa, ya) = stroke[i];
          final ((c1x, c1y), (c2x, c2y)) = controls[i];
          final a = geometry.toViewOffset(xa, ya);
          final c1 = geometry.toViewOffset(c1x, c1y);
          final c2 = geometry.toViewOffset(c2x, c2y);
          final b = geometry.toViewOffset(stroke[i + 1].$1, stroke[i + 1].$2);
          segment.strokeWidth = pdfInkStrokeWidth(
              strokeWidth, (pressure[i] + pressure[i + 1]) / 2);
          canvas.drawPath(
              Path()
                ..moveTo(a.dx, a.dy)
                ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, b.dx, b.dy),
              segment);
        }
        continue;
      }
      final start = geometry.toViewOffset(stroke.first.$1, stroke.first.$2);
      final path = Path()..moveTo(start.dx, start.dy);
      for (var i = 0; i < stroke.length - 1; i++) {
        final ((c1x, c1y), (c2x, c2y)) = controls[i];
        final c1 = geometry.toViewOffset(c1x, c1y);
        final c2 = geometry.toViewOffset(c2x, c2y);
        final p = geometry.toViewOffset(stroke[i + 1].$1, stroke[i + 1].$2);
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy);
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
    final ghost = this.ghost;
    final ghostFrom = this.ghostFrom;
    if (dragging && selection != null && ghost != null && ghostFrom != null) {
      paintAnnotationDragPreview(canvas,
          picture: ghost,
          from: ghostFrom,
          to: selection,
          scale: geometry.scale,
          rotation: rotation);
    }
    if (selection != null) {
      canvas.save();
      if (rotation != 0) {
        canvas.translate(selection.center.dx, selection.center.dy);
        canvas.rotate(rotation);
        canvas.translate(-selection.center.dx, -selection.center.dy);
      }
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
          final knob = Rect.fromCircle(center: center, radius: _handleSize / 2);
          canvas.drawRect(knob, fill);
          canvas.drawRect(knob, stroke);
        }
      }
      if (showRotateHandle) {
        final stroke = Paint()
          ..color = _chrome
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        final knob = Offset(
            box.center.dx, box.top - _rotateHandleDistance + 2);
        canvas.drawLine(box.topCenter, knob, stroke);
        canvas.drawCircle(
            knob, _handleSize / 2 + 1, Paint()..color = const Color(0xFFFFFFFF));
        canvas.drawCircle(knob, _handleSize / 2 + 1, stroke);
      }
      canvas.restore();
    }

    final element = elementRect;
    if (element != null) {
      final box = element.inflate(2);
      canvas.drawRect(box, Paint()..color = const Color(0x1AFB8C00));
      canvas.drawRect(
          box,
          Paint()
            ..color = _elementChrome
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_EditingPreviewPainter oldDelegate) =>
      oldDelegate.tool != tool ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.dragRect != dragRect ||
      oldDelegate.selectionRect != selectionRect ||
      oldDelegate.ghost != ghost ||
      oldDelegate.ghostFrom != ghostFrom ||
      oldDelegate.dragging != dragging ||
      oldDelegate.rotation != rotation ||
      oldDelegate.showHandles != showHandles ||
      oldDelegate.showRotateHandle != showRotateHandle ||
      oldDelegate.elementRect != elementRect ||
      oldDelegate.strokes.length != strokes.length ||
      (strokes.isNotEmpty &&
          oldDelegate.strokes.isNotEmpty &&
          oldDelegate.strokes.last.length != strokes.last.length);
}

/// Paints [picture] — an annotation appearance recorded in page raster
/// space (1 unit = 1 point, y down; see
/// [PdfPageRenderer.renderAnnotationPicture]) — mapped from its resting
/// view rect [from] onto [to], the live preview of a move/resize drag.
/// [scale] is the view's pixels-per-point.
///
/// Drawn at ~75% opacity: solid enough to judge the result, light
/// enough to read as a preview over the still-rendered original.
///
/// [rotation] (view radians, clockwise positive) additionally spins the
/// preview about [to]'s center — the rotate handle's live feedback.
@visibleForTesting
void paintAnnotationDragPreview(
  Canvas canvas, {
  required ui.Picture picture,
  required Rect from,
  required Rect to,
  required double scale,
  double rotation = 0,
}) {
  if (from.width <= 0 || from.height <= 0) return;
  final bounds = rotation == 0
      ? to.inflate(4)
      : Rect.fromCircle(
          center: to.center,
          radius: Offset(to.width, to.height).distance / 2 + 4);
  canvas.saveLayer(bounds, Paint()..color = const Color(0xBFFFFFFF));
  if (rotation != 0) {
    canvas.translate(to.center.dx, to.center.dy);
    canvas.rotate(rotation);
    canvas.translate(-to.center.dx, -to.center.dy);
  }
  canvas.translate(to.left, to.top);
  canvas.scale(to.width / from.width, to.height / from.height);
  canvas.translate(-from.left, -from.top);
  canvas.scale(scale, scale);
  canvas.drawPicture(picture);
  canvas.restore();
}
