import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf_document/pdf_document.dart';

import '../page_geometry.dart';
import '../renderer.dart';
import '../theme.dart';
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
    this.pageColor = const Color(0xFFFFFFFF),
    this.onPanViewport,
    this.rasterCurrent = true,
    this.zoom = 1,
    this.formImagePicker,
    this.onShowAnnotationMenu,
  });

  final PdfEditingController controller;
  final int pageIndex;
  final PdfPageGeometry geometry;
  final PdfTextPrompt textPrompt;

  /// How the form tool asks for a push-button field's image. With none,
  /// tapping a push button does nothing.
  final PdfFormImagePicker? formImagePicker;

  /// The paper color the page is displayed with — the eyedropper's
  /// raster must match what's on screen.
  final Color pageColor;

  /// Pans the viewer by a pointer delta (this overlay's local space).
  /// Lets a drag on empty page area scroll the document even though the
  /// overlay's recognizers won the arena — grab panning and annotation
  /// selection co-existing in the select tool.
  final void Function(Offset delta)? onPanViewport;

  /// Whether the page raster on screen already shows the controller's
  /// current revision. While false (an edit just committed and the
  /// re-render is in flight), the overlay keeps painting the committed
  /// edit's preview — its afterimage — so the edit never blinks out.
  final bool rasterCurrent;

  /// Screen pixels per overlay pixel — the viewer's transform zoom. The
  /// overlay paints inside that transform, so selection chrome (outline,
  /// handles, the rotate knob) divides its sizes and hit radii by this
  /// to stay constant-size on screen at any zoom. Page-content previews
  /// (ink, shapes, the drag ghost) scale with the page on purpose.
  final double zoom;

  /// Opens the annotation context menu at a global position — the
  /// selection action chip's "more" button, which gives touch input the
  /// menu that mice reach by right-clicking. The viewer supplies its
  /// menu (including the host's custom actions).
  final void Function(Offset globalPosition)? onShowAnnotationMenu;

  @override
  State<EditingPageOverlay> createState() => _EditingPageOverlayState();
}

/// A set of strokes the preview painter draws beyond the pending ink:
/// committed-ink afterimages and the signature tool's live preview.
/// Strokes are page-space; [strokeWidth] is view pixels.
typedef _InkPaint = ({
  List<List<(double, double)>> strokes,
  List<List<double>?> pressures,
  Color color,
  double strokeWidth,
});

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

class _EditingPageOverlayState extends State<EditingPageOverlay>
    with SingleTickerProviderStateMixin {
  // shape/text/stamp drag
  Offset? _dragStart;
  Offset? _dragCurrent;

  // eyedropper: one page raster serves every preview sample
  PdfPageColorSampler? _sampler;
  PdfDocument? _samplerDocument;
  Color? _samplerPageColor;
  Future<PdfPageColorSampler>? _samplerFuture;
  Offset? _pickPosition;
  Color? _pickPreview;

  // ink
  List<(double, double)>? _activeStroke;
  List<double>? _activeStrokePressures;

  /// The latest normalized pressure of the pointer being tracked, or null
  /// for devices that don't report pressure (finger, mouse).
  double? _pointerPressure;

  // raw-driven drawing: with ink or the eraser armed, stylus pointers
  // (and touch, when fingers draw) skip the gesture arena entirely — a
  // pan recognizer only wins after ~36px of motion, which swallowed the
  // start of every pencil stroke and dropped quick dots as taps. The
  // pointer id claims the gesture; moves append, up commits.
  int? _rawPointer;
  bool _rawErasing = false;

  /// Concurrent touch pointers on this page. A second finger landing
  /// mid-gesture aborts it (see [_bailActiveGesture]) instead of feeding
  /// both fingers' positions into one stroke.
  final Set<int> _touchPointers = {};

  /// True from a multi-touch bail until every touch pointer lifts —
  /// the remainder of the gesture is dead air.
  bool _gestureBailed = false;

  /// The device kind of the latest pointer down on this page — the
  /// selection action chip only shows for touch and stylus input.
  PointerDeviceKind? _lastPointerKind;

  // circle eraser: the swipe's swept path (page space), the live-sliced
  // remainder per touched /Annots slot (painted over the faded
  // original, so the preview shows exactly what the commit keeps),
  // touched annotations' view rects (washed while pending), inkless
  // slots that can only be deleted whole, and the ring cursor's view
  // position (drag for any pointer, hover for a mouse)
  final List<(double, double)> _erasePath = [];
  final Map<int, _InkPaint> _eraseSliced = {};
  final Map<int, Rect> _eraseRects = {};
  final Set<int> _eraseWholeSlots = {};
  Offset? _eraserCursor;
  bool _panErasing = false; // a mouse drag is erasing (arena path)

  /// Erase results kept painted until the new revision's raster lands —
  /// without them the old strokes pop back at full strength for a frame.
  List<Rect>? _afterEraseRects;
  List<_InkPaint>? _afterEraseInk;

  // in-place text editor: open after a free-text drag-out (new) or a
  // tap on the already-selected free text annotation (existing)
  Rect? _textEditRect; // view space; null = closed
  bool _textEditExisting = false;
  PdfEditTool? _textEditTool;
  late final TextEditingController _textEditText = TextEditingController();
  late final FocusNode _textEditFocus = FocusNode()
    ..addListener(_onTextEditFocus);
  PdfStandardFont _textEditFont = PdfStandardFont.helvetica;
  double _textEditSize = 14; // pt
  Color _textEditColor = const Color(0xFF000000);
  Color? _textEditFill; // the box background the commit will paint

  // form-tool text fill: when set, the inline editor commits into this
  // field's /V instead of creating a free-text annotation
  String? _textEditFieldName;
  bool _textEditMultiline = true;

  // select-tool drags. A rotated selection resizes in its local frame:
  // _resizeFrom/_resizeRect are then the chrome's local box (the rect
  // the painter spins by _resizeAngle), not page-axis view rects.
  Offset? _moveStart;
  Offset? _moveCurrent;
  _Handle? _resizeHandle;
  Rect? _resizeFrom;
  Rect? _resizeRect;
  double _resizeAngle = 0;

  // rubber-band selection (mouse drags on empty page area)
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;
  bool _marqueeAdd = false;

  // touch drags on empty page area pan the viewer instead
  bool _viewportPanning = false;

  // rotate drag: the pointer's start angle about the selection center,
  // the annotation's resting rotation when the drag started, and the
  // current delta (view space, clockwise positive — y is down)
  double? _rotateStartAngle;
  double _rotateResting = 0;
  double _rotateDelta = 0;

  // signature tool: the pointer position the live preview rides (hover
  // for a mouse, press-and-drag for touch), and whether a drag-place is
  // in flight
  Offset? _signaturePreview;
  bool _signatureDrag = false;

  // afterimage of the last commit, painted until the new revision's
  // raster lands ([widget.rasterCurrent]) — without it the preview
  // clears frames before the page re-renders and the edit blinks out
  PdfDocument? _afterDocument;
  ui.Picture? _afterGhost;
  Rect? _afterGhostFrom;
  Rect? _afterGhostTo;
  double _afterGhostRotation = 0;
  double _afterGhostLocalAngle = 0;
  ({Rect rect, PdfEditTool tool, Color color, double strokeWidth})?
      _afterShape;
  ({
    Rect rect,
    String text,
    PdfStandardFont font,
    double size,
    Color color,
    Color? fill,
    bool washed,
  })? _afterText;
  _InkPaint? _afterSignature;

  // live drag preview: the selected annotation's appearance, rendered
  // once per (revision, selection) and drawn stretched while dragging
  ui.Picture? _ghost;
  (PdfDocument, int, int)? _ghostKey;

  // attention flash (the annotation sidebar's zoom-to): an amber pulse
  // closing in on the annotation, driven by its own short animation
  late final AnimationController _flashController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..addListener(_onFlashTick)
    ..addStatusListener(_onFlashStatus);
  int _flashSequence = 0;
  PdfRect? _flashRect; // page space — view rect derives per build

  void _onFlashTick() => setState(() {});

  void _onFlashStatus(AnimationStatus status) {
    // pulse done: retire the pending flash so the overlay can unmount
    if (status == AnimationStatus.completed) {
      _controller.expireFlash(_flashSequence);
    }
  }

  MouseCursor _cursor = MouseCursor.defer;

  PdfEditingController get _controller => widget.controller;
  PdfPageGeometry get _geometry => widget.geometry;

  /// Overlay pixels per intended screen pixel for chrome metrics — the
  /// inverse of the viewer's transform zoom (see [EditingPageOverlay.zoom]).
  double get _chromeScale {
    final zoom = widget.zoom;
    return zoom.isFinite && zoom > 0 ? 1 / zoom : 1.0;
  }

  /// Null while the eyedropper is armed without a tool, or while a
  /// default-mode (mouse click) selection exists without one.
  PdfEditTool? get _tool => _controller.tool;

  /// Select-tool behavior applies: the tool is armed, or an annotation
  /// was selected in default mode (no tool) by a mouse click — the
  /// selection needs its move/resize/marquee interactions either way.
  bool get _selectMode =>
      _tool == PdfEditTool.select ||
      (_tool == null && _controller.hasAnnotationSelection);

  /// Shift/⌘/Ctrl held — a click toggles membership, a marquee adds.
  static bool get _additiveModifier {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isShiftPressed ||
        keyboard.isMetaPressed ||
        keyboard.isControlPressed;
  }

  static double? _normalizedPressure(PointerEvent event) =>
      event.pressureMax > event.pressureMin
          ? ((event.pressure - event.pressureMin) /
                  (event.pressureMax - event.pressureMin))
              .clamp(0.0, 1.0)
          : null;

  bool get _drawTool =>
      _tool == PdfEditTool.ink || _tool == PdfEditTool.eraser;

  /// Whether a pointer of [kind] draws (or erases) through the raw
  /// event stream instead of the gesture arena. Pan recognizers only
  /// win the arena after ~36px of motion, which swallowed the start of
  /// every pencil stroke and dropped quick dots as taps — so with ink
  /// or the eraser armed, stylus input (and touch, when fingers draw)
  /// starts on pointer-down. Mouse and trackpad keep the arena path:
  /// they have no latency problem and hover/click semantics to honor.
  bool _rawDrives(PointerDeviceKind? kind) {
    if (!_drawTool) return false;
    return switch (kind) {
      PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
      PointerDeviceKind.touch => _controller.fingerDrawsInk,
      _ => false,
    };
  }

  /// Raw-pointer bookkeeping the pan callbacks can't see: the pressure
  /// stream, stylus detection for palm rejection, multi-touch bail, and
  /// — with ink or the eraser armed — the stroke itself.
  void _onPointerDown(PointerDownEvent event) {
    _pointerPressure = _normalizedPressure(event);
    if (_lastPointerKind != event.kind) {
      // the selection action chip shows for touch/stylus input only
      setState(() => _lastPointerKind = event.kind);
    }
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers.add(event.pointer);
      if (_touchPointers.length >= 2) {
        // a stylus stroke survives stray touches — that second contact
        // is the palm resting on the screen, not a gesture
        if (_rawPointer != null && !_touchPointers.contains(_rawPointer)) {
          return;
        }
        _bailActiveGesture();
        return;
      }
    }
    if (_controller.isPickingColor) {
      _updatePickPreview(event.localPosition);
      return;
    }
    if (_gestureBailed) return;
    if (_drawTool &&
        _controller.fingerDrawsInk &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      // an Apple Pencil (or other stylus) is in play: from now on the
      // pen draws and fingers scroll, until the user toggles it back
      _controller.fingerDrawsInk = false;
    }
    if (_rawPointer == null && _rawDrives(event.kind)) {
      _rawPointer = event.pointer;
      // a flipped pencil erases even while the ink tool is armed —
      // that's what the flip is for
      _rawErasing = _tool == PdfEditTool.eraser ||
          event.kind == PointerDeviceKind.invertedStylus;
      if (_rawErasing) {
        _eraseAt(event.localPosition);
      } else {
        // hold the auto-commit while this stroke is on the page
        _controller.beginInkStroke();
        final pressure = _pointerPressure;
        setState(() {
          _activeStroke = [_geometry.toPagePoint(event.localPosition)];
          _activeStrokePressures = pressure == null ? null : [pressure];
        });
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final pressure = _normalizedPressure(event);
    if (pressure != null) _pointerPressure = pressure;
    if (_controller.isPickingColor) {
      _updatePickPreview(event.localPosition);
      return;
    }
    if (event.pointer != _rawPointer) return;
    if (_rawErasing) {
      _eraseAt(event.localPosition);
    } else if (_activeStroke != null) {
      setState(() {
        _activeStroke!.add(_geometry.toPagePoint(event.localPosition));
        _activeStrokePressures
            ?.add(_pointerPressure ?? _activeStrokePressures!.last);
      });
    }
  }

  /// Aborts whatever gesture is in flight — a second finger landed, so
  /// the first one wasn't drawing or dragging after all (it's a pinch,
  /// or just a clumsy grip). Nothing commits; the rest of the gesture
  /// is dead air until every touch pointer lifts.
  void _bailActiveGesture() {
    _gestureBailed = true;
    _rawPointer = null;
    _rawErasing = false;
    setState(() {
      _activeStroke = null;
      _activeStrokePressures = null;
      _resetErase();
      _panErasing = false;
      _dragStart = null;
      _dragCurrent = null;
      _moveStart = null;
      _moveCurrent = null;
      _resizeHandle = null;
      _resizeFrom = null;
      _resizeRect = null;
      _resizeAngle = 0;
      _rotateStartAngle = null;
      _rotateDelta = 0;
      _marqueeStart = null;
      _marqueeCurrent = null;
      _marqueeAdd = false;
      _viewportPanning = false;
      _signatureDrag = false;
      _signaturePreview = null;
    });
    // earlier strokes waiting in the buffer get their auto-commit back
    _controller.cancelInkStroke();
  }

  /// Touch bookkeeping and the raw gesture's commit, shared by
  /// pointer-up and pointer-cancel.
  void _endRawPointer(PointerEvent event, {required bool canceled}) {
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers.remove(event.pointer);
      if (_touchPointers.isEmpty) _gestureBailed = false;
    }
    if (event.pointer != _rawPointer) return;
    _rawPointer = null;
    final erasing = _rawErasing;
    _rawErasing = false;
    if (erasing) {
      if (canceled) {
        setState(_resetErase);
      } else {
        _commitErase();
      }
      return;
    }
    final stroke = _activeStroke;
    final pressures = _activeStrokePressures;
    setState(() {
      _activeStroke = null;
      _activeStrokePressures = null;
    });
    if (canceled || stroke == null || stroke.isEmpty) {
      _controller.cancelInkStroke();
      return;
    }
    if (stroke.length == 1) {
      // a dot (the i's, mostly): a zero-length segment renders as a
      // filled circle under the round line cap (PDF §8.5.3.2)
      stroke.add(stroke.single);
      pressures?.add(pressures.single);
    }
    _controller.addInkStroke(widget.pageIndex, stroke,
        pressures: pressures);
  }

  /// Sweeps the circle eraser to the view-space [position]: extends the
  /// swipe's path by one capsule and re-slices every ink annotation it
  /// touches, so the live preview (faded original + remainder strokes)
  /// shows exactly what the commit will keep. Ink annotations without a
  /// usable /InkList can't be sliced — they fade whole and the commit
  /// deletes them.
  void _eraseAt(Offset position) {
    final point = _geometry.toPagePoint(position);
    final radius = _controller.eraserRadius;
    final from = _erasePath.isEmpty ? point : _erasePath.last;
    setState(() {
      _eraserCursor = position;
      _erasePath.add(point);
      final annotations = _controller.pageAt(widget.pageIndex).annotations;
      for (var slot = 0; slot < annotations.length; slot++) {
        final annotation = annotations[slot];
        if (annotation.subtype != 'Ink' || annotation.isHidden) continue;
        final tracked = _eraseSliced[slot];
        final strokes = tracked?.strokes ?? annotation.inkList;
        if (strokes == null) {
          if (!_eraseWholeSlots.contains(slot) &&
              _hitsRect(point, annotation.rect, radius)) {
            _eraseWholeSlots.add(slot);
            _eraseRects[slot] = _geometry.toViewRect(annotation.rect);
          }
          continue;
        }
        final sliced = pdfSliceInkStrokes(strokes, null, from, point, radius);
        if (sliced == null) continue;
        _eraseRects[slot] ??= _geometry.toViewRect(annotation.rect);
        _eraseSliced[slot] = (
          strokes: sliced.strokes,
          pressures:
              List<List<double>?>.filled(sliced.strokes.length, null),
          color: Color(0xFF000000 | (annotation.color ?? 0xD02020)),
          strokeWidth: (annotation.borderWidth ?? 1) * _geometry.scale,
        );
      }
    });
  }

  static bool _hitsRect((double, double) p, PdfRect rect, double radius) =>
      p.$1 >= rect.left - radius &&
      p.$1 <= rect.right + radius &&
      p.$2 >= rect.bottom - radius &&
      p.$2 <= rect.top + radius;

  void _resetErase() {
    _erasePath.clear();
    _eraseSliced.clear();
    _eraseWholeSlots.clear();
    _eraseRects.clear();
    _eraserCursor = null;
  }

  /// Commits the swipe's slicing in one apply (one undo) and keeps the
  /// washed rects plus the sliced remainders painted until the new
  /// revision's raster lands.
  void _commitErase() {
    final path = List.of(_erasePath);
    final rects = List.of(_eraseRects.values);
    final ink = List.of(_eraseSliced.values);
    final touched = _eraseSliced.isNotEmpty || _eraseWholeSlots.isNotEmpty;
    setState(_resetErase);
    if (path.isEmpty || !touched) return;
    final before = _controller.document;
    _controller.sliceErase(widget.pageIndex, path);
    if (identical(before, _controller.document)) return;
    _clearAfterimage();
    _afterEraseRects = rects;
    _afterEraseInk = ink;
    _afterDocument = _controller.document;
  }

  /// The primary selected annotation's view rect when it lives on this
  /// page — the one that gets resize/rotate handles (single selection).
  Rect? get _selectedViewRect {
    if (_controller.selectedPage != widget.pageIndex) return null;
    final annotation = _controller.selectedAnnotation;
    return annotation == null ? null : _geometry.toViewRect(annotation.rect);
  }

  /// Every selected annotation's view rect on this page, in selection
  /// order (so the primary is last).
  List<Rect> get _selectedViewRects => [
        for (final slot in _controller.selectedAnnotationSlots)
          if (slot.$1 == widget.pageIndex)
            if (_controller.annotationAt(slot.$1, slot.$2)
                case final annotation?)
              _geometry.toViewRect(annotation.rect)
      ];

  /// The primary selection's appearance quad in view space (BBox corner
  /// order: ll, lr, ur, ul), or null without an appearance stream.
  List<Offset>? get _selectedViewQuad {
    if (_controller.selectedPage != widget.pageIndex) return null;
    final quad = _controller.selectedAnnotation?.appearanceQuad;
    if (quad == null) return null;
    return [for (final (x, y) in quad) _geometry.toViewOffset(x, y)];
  }

  /// The view-space rotation of [quad]'s bottom edge — the angle the
  /// selection chrome spins by (canvas.rotate convention: clockwise
  /// positive). Numeric noise within ~0.3° reads as unrotated.
  static double _quadAngle(List<Offset> quad) {
    final edge = quad[1] - quad[0];
    if (edge.distance <= 0) return 0;
    final angle = edge.direction;
    return angle.abs() < 0.005 ? 0 : angle;
  }

  /// The selection chrome's box and resting rotation: the axis-aligned
  /// view rect for an unrotated appearance, otherwise the quad's own
  /// (pre-rotation) rectangle — the painter spins it back into place,
  /// so the chrome hugs the rotated artwork instead of boxing its
  /// axis-aligned bounds.
  (Rect, double)? get _selectionChrome {
    final selected = _selectedViewRect;
    if (selected == null) return null;
    final quad = _selectedViewQuad;
    if (quad == null) return (selected, 0);
    final angle = _quadAngle(quad);
    if (angle == 0) return (selected, 0);
    final center = Offset(
        (quad[0].dx + quad[2].dx) / 2, (quad[0].dy + quad[2].dy) / 2);
    return (
      Rect.fromCenter(
        center: center,
        width: (quad[1] - quad[0]).distance,
        height: (quad[3] - quad[0]).distance,
      ),
      angle,
    );
  }

  static Offset _rotatePoint(Offset p, Offset center, double angle) {
    final d = p - center;
    final c = math.cos(angle), s = math.sin(angle);
    return center + Offset(d.dx * c - d.dy * s, d.dx * s + d.dy * c);
  }

  /// Drops the afterimage (and its ghost picture, which the state owns).
  void _clearAfterimage() {
    _afterGhost?.dispose();
    _afterGhost = null;
    _afterGhostFrom = null;
    _afterGhostTo = null;
    _afterGhostRotation = 0;
    _afterGhostLocalAngle = 0;
    _afterShape = null;
    _afterText = null;
    _afterSignature = null;
    _afterEraseRects = null;
    _afterEraseInk = null;
    _afterDocument = null;
  }

  /// Runs [commit] and, when it produced a new revision, keeps the
  /// current ghost painted at [to] (spun by [rotation]) as the
  /// afterimage — the move/resize/rotate result stays visible while the
  /// page re-renders. The ghost's ownership transfers to the afterimage;
  /// [_ensureGhost] re-renders a fresh one for the new revision.
  ///
  /// For a rotated selection's resize, [localAngle] is its resting
  /// rotation and [to] the dragged *local* box — the afterimage then
  /// scales along the local axes, exactly like the live preview did.
  void _commitWithGhost(VoidCallback commit,
      {Rect? to, double rotation = 0, double localAngle = 0}) {
    final from =
        localAngle == 0 ? _selectedViewRect : _selectionChrome?.$1;
    final ghost = _ghost;
    final before = _controller.document;
    commit();
    if (identical(before, _controller.document)) return;
    if (ghost == null || from == null || to == null) return;
    _clearAfterimage();
    _ghost = null;
    _ghostKey = null;
    _afterGhost = ghost;
    _afterGhostFrom = from;
    _afterGhostTo = to;
    _afterGhostRotation = rotation;
    _afterGhostLocalAngle = localAngle;
    _afterDocument = _controller.document;
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
    // only a single selection drags with its artwork; a multi-selection
    // moves as plain chrome boxes
    final slot = _controller.selectedAnnotationSlots.length == 1
        ? _controller.selectedAnnotationSlot
        : null;
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
    if (_textEditRect != null) _controller.setEditingText(false);
    _textEditFocus
      ..removeListener(_onTextEditFocus)
      ..dispose();
    _textEditText.dispose();
    _ghost?.dispose();
    _afterGhost?.dispose();
    _flashController.dispose();
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
          _handleHitRadius * _chromeScale) {
        return handle;
      }
    }
    return null;
  }

  /// The rotate knob's view position: above the chrome box's top edge,
  /// riding the annotation's resting [rotation] about the box center.
  Offset _rotateHandleCenter(Rect rect, double rotation) => _rotatePoint(
        Offset(rect.center.dx,
            rect.top - _rotateHandleDistance * _chromeScale),
        rect.center,
        rotation,
      );

  /// Resize handles get first claim (the top-center knob sits close),
  /// so this is only consulted after [_handleAt] misses.
  bool _hitsRotateHandle(Rect rect, double rotation, Offset position) =>
      _controller.canRotateSelected &&
      (position - _rotateHandleCenter(rect, rotation)).distance <=
          _handleHitRadius * _chromeScale;

  /// The drag's rotation delta for the pointer at [position]: the angle
  /// swept about the selection center. The *total* rotation (resting +
  /// delta) snaps near 45° multiples, so a rotated annotation can snap
  /// back to square.
  double _rotationDelta(Rect selected, Offset position) {
    var delta = (position - selected.center).direction - _rotateStartAngle!;
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    while (delta <= -math.pi) {
      delta += 2 * math.pi;
    }
    final total = _rotateResting + delta;
    final snapped = (total / (math.pi / 4)).round() * (math.pi / 4);
    return (total - snapped).abs() <= _rotateSnapRadians
        ? snapped - _rotateResting
        : delta;
  }

  Rect _resizedRect(Rect from, _Handle handle, Offset delta) {
    final minSize = _minSizeView * _chromeScale;
    var left = from.left, top = from.top;
    var right = from.right, bottom = from.bottom;
    if (handle.dx < 0) left += delta.dx;
    if (handle.dx > 0) right += delta.dx;
    if (handle.dy < 0) top += delta.dy;
    if (handle.dy > 0) bottom += delta.dy;
    // never collapse or invert: the dragged side stops at the minimum
    if (right - left < minSize) {
      if (handle.dx < 0) {
        left = right - minSize;
      } else {
        right = left + minSize;
      }
    }
    if (bottom - top < minSize) {
      if (handle.dy < 0) {
        top = bottom - minSize;
      } else {
        bottom = top + minSize;
      }
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  // -----------------------------------------------------------------
  // in-place text editing

  /// Opens the inline text editor over [viewRect] — empty for a fresh
  /// free-text box, prefilled from the selected annotation when
  /// [existing]. The editor renders with the same font, size, and color
  /// the committed annotation will use.
  void _openTextEditor(Rect viewRect, {required bool existing}) {
    final style = existing ? _controller.selectedTextStyle : null;
    // /DA carries the text color; /C is the box background for free text
    final annotation = existing ? _controller.selectedAnnotation : null;
    final parsed = annotation?.freeTextStyle;
    final annotationColor = parsed?.color ?? annotation?.color;
    _textEditText.text = existing ? (_controller.selectedText ?? '') : '';
    setState(() {
      _textEditRect = viewRect;
      _textEditExisting = existing;
      _textEditTool = _tool;
      _textEditFont = style?.font ?? _controller.fontFamily;
      _textEditSize = style?.size ?? _controller.fontSize;
      _textEditColor = annotationColor != null
          ? Color(0xFF000000 | annotationColor)
          : _controller.color;
      _textEditFill = existing
          ? (parsed?.fillColor != null
              ? Color(0xFF000000 | parsed!.fillColor!)
              : null)
          : _controller.textFillColor;
    });
    _controller.setEditingText(true);
    // the field's autofocus is ignored: the creating gesture's
    // pointer-down put primary focus on the viewer's own node, and
    // autofocus only fires into an unfocused scope — claim it so typing
    // lands in the fresh box without clicking into it first
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _textEditRect != null) _textEditFocus.requestFocus();
    });
  }

  /// Opens the inline editor over a text field's widget, prefilled with
  /// its value — the form tool's tap-to-fill. The commit goes into the
  /// field's /V instead of creating an annotation.
  void _openFormTextEditor(PdfFormField field, int widgetIndex) {
    final rect = field.widgetRect(widgetIndex);
    if (rect == null) return;
    final tf = RegExp(r'/(\S+)\s+(\d+(?:\.\d+)?)\s+Tf')
        .firstMatch(field.defaultAppearance ?? '');
    final size = double.tryParse(tf?.group(2) ?? '') ?? 0;
    _textEditText.text = field.value ?? '';
    setState(() {
      _textEditRect = _geometry.toViewRect(rect);
      _textEditExisting = false;
      _textEditTool = _tool;
      _textEditFieldName = field.name;
      _textEditMultiline = field.isMultiline;
      _textEditFont = tf == null
          ? PdfStandardFont.helvetica
          : PdfStandardFont.fromName(tf.group(1)!);
      // an auto-size /DA (0 Tf) edits at a readable default; the
      // committed appearance derives its own size as usual
      _textEditSize = size > 0 ? size : 12;
      _textEditColor = const Color(0xFF000000);
      _textEditFill = null;
    });
    _controller.setEditingText(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _textEditRect != null) _textEditFocus.requestFocus();
    });
  }

  /// Commits the editor's text: a new free-text annotation, the
  /// selected one rewritten, or — for the form tool — the field's new
  /// value. Empty text adds nothing / changes nothing.
  void _commitTextEdit() {
    final rect = _textEditRect;
    if (rect == null) return;
    final fieldName = _textEditFieldName;
    if (fieldName != null) {
      // form fields: empty is a legitimate value (clearing the field)
      final value = _textEditText.text;
      final font = _textEditFont;
      final size = _textEditSize;
      _closeTextEditor();
      final before = _controller.document;
      _controller.setFormFieldText(fieldName, value);
      if (identical(before, _controller.document)) return;
      _clearAfterimage();
      _afterText = (
        rect: rect,
        text: value,
        font: font,
        size: size,
        color: const Color(0xFF000000),
        fill: null,
        washed: true, // cover the old value until the raster lands
      );
      _afterDocument = _controller.document;
      return;
    }
    final text = _textEditText.text.trimRight();
    final existing = _textEditExisting;
    final font = _textEditFont;
    final size = _textEditSize;
    final color = _textEditColor;
    final fill = _textEditFill;
    _closeTextEditor();
    final before = _controller.document;
    if (existing) {
      if (text.isNotEmpty && text != _controller.selectedText) {
        _controller.setSelectedText(text);
      }
    } else if (text.isNotEmpty) {
      _controller.addFreeText(
          widget.pageIndex, _geometry.toPageRect(rect), text);
    }
    if (identical(before, _controller.document)) return;
    // the editor's rendering, frozen until the new revision's raster
    // lands — otherwise the text vanishes for the render's duration
    _clearAfterimage();
    _afterText = (
      rect: rect,
      text: text,
      font: font,
      size: size,
      color: color,
      fill: fill,
      washed: existing,
    );
    _afterDocument = _controller.document;
  }

  void _cancelTextEdit() => _closeTextEditor();

  void _closeTextEditor() {
    if (_textEditRect == null) return;
    if (mounted) {
      setState(() {
        _textEditRect = null;
        _textEditFieldName = null;
      });
    } else {
      _textEditRect = null;
      _textEditFieldName = null;
    }
    _controller.setEditingText(false);
  }

  /// Losing focus commits — tapping another widget, switching panes.
  /// (Escape cancels first, so by the time the unfocus arrives the
  /// session is already gone and this is a no-op.)
  void _onTextEditFocus() {
    if (!_textEditFocus.hasFocus) _commitTextEdit();
  }

  void _panStart(DragStartDetails details) {
    // raw-driven pointers own their gesture: the pan recognizer still
    // claims the arena (keeping the viewer's pan/zoom from fighting the
    // stroke) but its callbacks must not double-drive it
    if (_gestureBailed || _rawDrives(details.kind)) return;
    final position = details.localPosition;
    if (_textEditRect != null) {
      // a drag outside the open editor commits it, like a tap
      _commitTextEdit();
      return;
    }
    if (_selectMode) {
      _selectPanStart(details);
      return;
    }
    switch (_tool) {
      case null:
        break; // eyedropper only — taps, no drags
      case PdfEditTool.select:
        break; // handled by _selectPanStart above
      case PdfEditTool.eraser:
        // mouse/trackpad erase through the arena like any drag
        _panErasing = true;
        _eraseAt(position);
      case PdfEditTool.ink:
        // hold the auto-commit while this stroke is on the page
        _controller.beginInkStroke();
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
      case PdfEditTool.form:
        // drag-out on empty page area adds a field; a drag starting on
        // an existing widget is not a creation gesture
        final (x, y) = _geometry.toPagePoint(position);
        if (_controller.formFieldAt(widget.pageIndex, x, y) == null) {
          setState(() {
            _dragStart = position;
            _dragCurrent = position;
          });
        }
      case PdfEditTool.signature:
        // press-drag-release placement: the preview rides the pointer
        // (touch has no hover), release commits where it landed
        if (_controller.signature != null) {
          setState(() {
            _signatureDrag = true;
            _signaturePreview = position;
          });
        }
      case PdfEditTool.note || PdfEditTool.content:
        break; // driven by taps
    }
  }

  /// Select-mode drags, by what's under the press: a handle resizes, the
  /// rotate knob spins, a selected annotation moves the whole selection,
  /// an unselected one is selected and moved in the same drag. Empty
  /// page area drags a rubber band with a mouse and pans the viewer with
  /// touch (so the document stays scrollable while selecting).
  void _selectPanStart(DragStartDetails details) {
    final position = details.localPosition;
    final selected = _selectedViewRect;
    final chrome = _selectionChrome;
    final resting = chrome?.$2 ?? 0;
    if (selected != null) {
      // a rotated selection resizes in its local frame: hit-test the
      // handles where they're drawn (on the spun chrome box) by
      // unrotating the pointer about the chrome center
      final handle = resting == 0 || chrome == null
          ? _handleAt(selected, position)
          : _handleAt(chrome.$1,
              _rotatePoint(position, chrome.$1.center, -resting));
      if (handle != null) {
        setState(() {
          _resizeHandle = handle;
          _resizeFrom = resting == 0 ? selected : chrome!.$1;
          _resizeRect = _resizeFrom;
          _resizeAngle = resting;
          _moveStart = position;
          _moveCurrent = position;
        });
        return;
      }
      if (chrome != null &&
          _hitsRotateHandle(chrome.$1, resting, position)) {
        setState(() {
          _rotateStartAngle = (position - selected.center).direction;
          _rotateResting = resting;
          _rotateDelta = 0;
        });
        return;
      }
    }
    // dragging any selected annotation moves the whole selection
    for (final rect in _selectedViewRects) {
      if (rect.contains(position)) {
        setState(() {
          _moveStart = position;
          _moveCurrent = position;
        });
        return;
      }
    }
    final (x, y) = _geometry.toPagePoint(position);
    if (_controller.selectableAnnotationAt(widget.pageIndex, x, y) != null) {
      // grab an unselected annotation: select it and move it in one drag
      _controller.selectAnnotationAt(widget.pageIndex, x, y);
      setState(() {
        _moveStart = position;
        _moveCurrent = position;
      });
      return;
    }
    final mouseLike = details.kind == null ||
        details.kind == PointerDeviceKind.mouse ||
        details.kind == PointerDeviceKind.trackpad;
    if (mouseLike) {
      setState(() {
        _marqueeStart = position;
        _marqueeCurrent = position;
        _marqueeAdd = _additiveModifier;
      });
    } else if (widget.onPanViewport != null) {
      _viewportPanning = true;
    }
  }

  void _panUpdate(DragUpdateDetails details) {
    if (_gestureBailed || _rawPointer != null) return;
    final position = details.localPosition;
    if (_panErasing) {
      _eraseAt(position);
      return;
    }
    if (_viewportPanning) {
      widget.onPanViewport?.call(details.delta);
      return;
    }
    if (_marqueeStart != null) {
      setState(() => _marqueeCurrent = position);
      return;
    }
    if (_signatureDrag) {
      setState(() => _signaturePreview = position);
      return;
    }
    if (_rotateStartAngle != null) {
      final selected = _selectedViewRect;
      if (selected == null) return;
      setState(() => _rotateDelta = _rotationDelta(selected, position));
    } else if (_resizeHandle != null) {
      setState(() {
        _moveCurrent = position;
        // a rotated selection's handles move along its own axes, so the
        // pointer delta rotates into the local frame
        final delta = position - _moveStart!;
        _resizeRect = _resizedRect(
            _resizeFrom!,
            _resizeHandle!,
            _resizeAngle == 0
                ? delta
                : _rotatePoint(delta, Offset.zero, -_resizeAngle));
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
    if (_rawPointer != null) return; // the raw pointer-up commits
    if (_panErasing) {
      _panErasing = false;
      _commitErase();
      return;
    }
    final stroke = _activeStroke;
    final strokePressures = _activeStrokePressures;
    final dragStart = _dragStart;
    final dragCurrent = _dragCurrent;
    final moveStart = _moveStart;
    final moveCurrent = _moveCurrent;
    final resizeRect = _resizeHandle != null ? _resizeRect : null;
    final resizeAngle = _resizeAngle;
    final rotating = _rotateStartAngle != null;
    final rotateDelta = _rotateDelta;
    final marquee = _marqueeStart != null && _marqueeCurrent != null
        ? Rect.fromPoints(_marqueeStart!, _marqueeCurrent!)
        : null;
    final marqueeAdd = _marqueeAdd;
    final panned = _viewportPanning;
    final signaturePlace = _signatureDrag ? _signaturePreview : null;
    setState(() {
      _activeStroke = null;
      _activeStrokePressures = null;
      _dragStart = null;
      _dragCurrent = null;
      _moveStart = null;
      _moveCurrent = null;
      _resizeHandle = null;
      _resizeFrom = null;
      _resizeRect = null;
      _resizeAngle = 0;
      _rotateStartAngle = null;
      _rotateDelta = 0;
      _marqueeStart = null;
      _marqueeCurrent = null;
      _marqueeAdd = false;
      _viewportPanning = false;
      _signatureDrag = false;
    });

    if (panned) return;
    if (signaturePlace != null) {
      _placeSignature(signaturePlace);
      return;
    }
    if (marquee != null) {
      if (marquee.width < 4 && marquee.height < 4) return; // a click
      _controller.selectAnnotationsIn(
          widget.pageIndex, _geometry.toPageRect(marquee),
          add: marqueeAdd);
      return;
    }
    if (rotating) {
      // view-space clockwise (y down) is page-space clockwise, and PDF
      // rotation is counterclockwise-positive — hence the sign flip
      _commitWithGhost(
          () => _controller.rotateSelected(-rotateDelta * 180 / math.pi),
          to: _selectedViewRect,
          rotation: rotateDelta);
    } else if (resizeRect != null) {
      if (resizeAngle == 0) {
        _commitWithGhost(
            () => _controller.resizeSelected(_geometry.toPageRect(resizeRect)),
            to: resizeRect);
      } else {
        // the dragged rect is the local box; the editor re-applies the
        // resting rotation about its center
        _commitWithGhost(
            () => _controller
                .resizeSelectedLocal(_geometry.toPageRect(resizeRect)),
            to: resizeRect,
            localAngle: resizeAngle);
      }
    } else if (moveStart != null && moveCurrent != null) {
      if ((moveCurrent - moveStart).distance < 2) return; // a click
      // mapping both endpoints keeps the delta correct on rotated pages
      final (x0, y0) = _geometry.toPagePoint(moveStart);
      final (x1, y1) = _geometry.toPagePoint(moveCurrent);
      _commitWithGhost(() => _controller.moveSelected(x1 - x0, y1 - y0),
          to: _selectedViewRect?.shift(moveCurrent - moveStart));
    } else if (stroke != null && stroke.isNotEmpty) {
      _controller.addInkStroke(widget.pageIndex, stroke,
          pressures: strokePressures);
    } else if (dragStart != null && dragCurrent != null) {
      final viewRect = Rect.fromPoints(dragStart, dragCurrent);
      if (viewRect.width < 4 || viewRect.height < 4) return; // a click
      if (_tool == PdfEditTool.freeText) {
        // type into the box just dragged out, instead of a dialog
        _openTextEditor(viewRect, existing: false);
      } else {
        _commitRect(viewRect);
      }
    }
  }

  /// Places the saved signature at the view-space [position] and keeps
  /// its preview painted as the afterimage while the page re-renders.
  void _placeSignature(Offset position) {
    final (x, y) = _geometry.toPagePoint(position);
    final placement =
        _controller.signaturePlacement(widget.pageIndex, x, y);
    if (placement == null) return;
    final before = _controller.document;
    _controller.placeSignature(widget.pageIndex, x, y);
    if (identical(before, _controller.document)) return;
    _clearAfterimage();
    _afterSignature = (
      strokes: placement.strokes,
      pressures: placement.pressures,
      color: Color(0xFF000000 | placement.color),
      strokeWidth: placement.strokeWidth * _geometry.scale,
    );
    _afterDocument = _controller.document;
    // the next hover re-arms the preview; touch shouldn't keep a stale one
    _signaturePreview = null;
  }

  Future<void> _commitRect(Rect viewRect) async {
    final rect = _geometry.toPageRect(viewRect);
    switch (_tool) {
      case PdfEditTool.rectangle || PdfEditTool.ellipse:
        final tool = _tool!;
        final before = _controller.document;
        if (tool == PdfEditTool.rectangle) {
          _controller.addRectangle(widget.pageIndex, rect);
        } else {
          _controller.addEllipse(widget.pageIndex, rect);
        }
        if (identical(before, _controller.document)) return;
        // the drag preview, frozen until the new revision renders
        _clearAfterimage();
        _afterShape = (
          rect: viewRect,
          tool: tool,
          color: _controller.color
              .withValues(alpha: _controller.opacity.clamp(0.0, 1.0)),
          strokeWidth: _controller.strokeWidth * _geometry.scale,
        );
        _afterDocument = _controller.document;
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
      case PdfEditTool.form:
        _controller.addFormField(
            _controller.newFormFieldKind, widget.pageIndex, rect);
      default:
        break;
    }
  }

  /// The form tool's tap: routes the hit field to its fill interaction.
  Future<void> _onFormTap(TapUpDetails details) async {
    final (x, y) = _geometry.toPagePoint(details.localPosition);
    final hit = _controller.formFieldAt(widget.pageIndex, x, y);
    if (hit == null) return;
    final (field, widgetIndex) = hit;
    if (field.isReadOnly) return;
    switch (field.type) {
      case PdfFieldType.text:
        _openFormTextEditor(field, widgetIndex);
      case PdfFieldType.checkBox:
        _controller.toggleFormCheckBox(field.name);
      case PdfFieldType.radioGroup:
        final state = field.widgetOnState(widgetIndex);
        if (state != null) _controller.setFormRadioValue(field.name, state);
      case PdfFieldType.comboBox || PdfFieldType.listBox:
        await _pickFormChoice(field, details.globalPosition);
      case PdfFieldType.pushButton:
        final picker = widget.formImagePicker;
        if (picker == null) return;
        final name = field.name;
        final bytes = await picker(context, field);
        if (bytes != null) _controller.setFormButtonImage(name, bytes);
      case PdfFieldType.signature || PdfFieldType.unknown:
        break;
    }
  }

  /// A choice field's options as a context menu at the tap position.
  Future<void> _pickFormChoice(
      PdfFormField field, Offset globalPosition) async {
    final options = field.options;
    if (options.isEmpty) return;
    final name = field.name;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          globalPosition & Size.zero, Offset.zero & overlay.size),
      items: [
        for (final (export, display) in options)
          PopupMenuItem(
            key: ValueKey('pdf-form-option-$export'),
            value: export,
            child: Text(display),
          ),
      ],
    );
    if (picked != null) _controller.setFormChoiceValue(name, picked);
  }

  /// Rasterizes this page once for the eyedropper, keyed on document
  /// identity (it changes every revision). The page raster at scale 1
  /// shares the view's orientation, so view → raster is just the
  /// geometry scale.
  Future<PdfPageColorSampler> _ensureSampler() {
    final document = _controller.document;
    final pageColor = widget.pageColor;
    if (!identical(document, _samplerDocument) ||
        pageColor != _samplerPageColor) {
      _samplerDocument = document;
      _samplerPageColor = pageColor;
      _sampler = null;
      _samplerFuture = PdfPageColorSampler.of(document.page(widget.pageIndex),
              pageColor: pageColor)
          .then((s) {
        // resolve the preview that was waiting on the raster
        if (mounted &&
            identical(_samplerDocument, document) &&
            _samplerPageColor == pageColor) {
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

  /// Releasing the pointer commits the raw gesture (stroke or erase
  /// swipe) and picks the eyedropper's previewed color — so both a
  /// plain tap and press-drag-release (watching the preview) work. A
  /// raw listener, so it fires regardless of the gesture arena.
  Future<void> _onPointerUp(PointerUpEvent event) async {
    _endRawPointer(event, canceled: false);
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

  void _onPointerCancel(PointerCancelEvent event) =>
      _endRawPointer(event, canceled: true);

  Future<void> _onTapUp(TapUpDetails details) async {
    // the eyedropper commits from the raw pointer-up instead
    if (_controller.isPickingColor) return;
    if (_gestureBailed) return;
    if (_tool == PdfEditTool.eraser) {
      // a mouse/trackpad click erases what's under it; raw-driven
      // pointers already handled theirs on the way down
      if (!_rawDrives(details.kind)) {
        _eraseAt(details.localPosition);
        _commitErase();
      }
      return;
    }
    if (_textEditRect != null) {
      // tapping outside the open editor commits it
      _commitTextEdit();
      return;
    }
    final (x, y) = _geometry.toPagePoint(details.localPosition);
    if (_selectMode) {
      // tapping the already-selected free text edits it in place,
      // like clicking into a text box in any editor
      if (_controller.selectedAnnotationSlots.length == 1 &&
          _controller.selectedAnnotationSlot?.$1 == widget.pageIndex &&
          _controller.selectedAnnotation?.subtype == 'FreeText' &&
          !_additiveModifier &&
          (_selectedViewRect?.contains(details.localPosition) ?? false)) {
        _openTextEditor(_selectedViewRect!, existing: true);
        return;
      }
      // shift/⌘-click toggles membership in the selection
      _controller.selectAnnotationAt(widget.pageIndex, x, y,
          toggle: _additiveModifier);
      return;
    }
    switch (_tool) {
      case null:
        break;
      case PdfEditTool.select:
        break; // handled above
      case PdfEditTool.content:
        _controller.selectElementAt(widget.pageIndex, x, y);
      case PdfEditTool.note:
        final text =
            await widget.textPrompt(context, title: 'Note', multiline: true);
        if (text == null || text.isEmpty) return;
        _controller.addNote(widget.pageIndex, x, y, text);
      case PdfEditTool.signature:
        _placeSignature(details.localPosition);
      case PdfEditTool.stamp:
        // no-op without an active custom stamp (the classic flow drags)
        _controller.placeStamp(widget.pageIndex, x, y);
      case PdfEditTool.form:
        await _onFormTap(details);
      default:
        break;
    }
  }

  void _onHover(PointerHoverEvent event) {
    final MouseCursor cursor;
    if (_controller.isPickingColor) {
      _updatePickPreview(event.localPosition);
      cursor = SystemMouseCursors.precise;
    } else if (_selectMode) {
      final selected = _selectedViewRect;
      final chrome = _selectionChrome;
      final resting = chrome?.$2 ?? 0;
      final handle = selected == null
          ? null
          : resting == 0 || chrome == null
              ? _handleAt(selected, event.localPosition)
              : _handleAt(chrome.$1,
                  _rotatePoint(event.localPosition, chrome.$1.center, -resting));
      if (handle != null) {
        cursor = switch ((handle.dx, handle.dy)) {
          (0, _) => SystemMouseCursors.resizeUpDown,
          (_, 0) => SystemMouseCursors.resizeLeftRight,
          (-1, -1) || (1, 1) => SystemMouseCursors.resizeUpLeftDownRight,
          _ => SystemMouseCursors.resizeUpRightDownLeft,
        };
      } else if (chrome != null &&
          _hitsRotateHandle(chrome.$1, resting, event.localPosition)) {
        cursor = SystemMouseCursors.grab;
      } else if (_selectedViewRects
          .any((rect) => rect.contains(event.localPosition))) {
        cursor = SystemMouseCursors.move;
      } else {
        final (x, y) = _geometry.toPagePoint(event.localPosition);
        // a pointer over a selectable annotation, a crosshair-ish basic
        // over empty page (a drag there rubber-bands)
        cursor =
            _controller.selectableAnnotationAt(widget.pageIndex, x, y) != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic;
      }
    } else if (_tool == PdfEditTool.note) {
      cursor = SystemMouseCursors.click;
    } else if (_tool == PdfEditTool.eraser) {
      // the painted ring is the cursor
      if (_eraserCursor != event.localPosition) {
        setState(() => _eraserCursor = event.localPosition);
      }
      cursor = SystemMouseCursors.none;
    } else if (_tool == PdfEditTool.signature) {
      // the live preview rides the mouse; a click commits it
      if (_controller.signature != null &&
          event.localPosition != _signaturePreview) {
        setState(() => _signaturePreview = event.localPosition);
      }
      cursor = SystemMouseCursors.precise;
    } else if (_tool == PdfEditTool.content) {
      final (x, y) = _geometry.toPagePoint(event.localPosition);
      cursor =
          _controller.elementsOn(widget.pageIndex).elementsAt(x, y).isNotEmpty
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic;
    } else if (_tool == PdfEditTool.form) {
      final (x, y) = _geometry.toPagePoint(event.localPosition);
      final hit = _controller.formFieldAt(widget.pageIndex, x, y);
      if (hit == null) {
        cursor = SystemMouseCursors.precise; // a drag here adds a field
      } else if (hit.$1.isReadOnly) {
        cursor = SystemMouseCursors.basic;
      } else {
        cursor = switch (hit.$1.type) {
          PdfFieldType.text => SystemMouseCursors.text,
          PdfFieldType.signature ||
          PdfFieldType.unknown =>
            SystemMouseCursors.basic,
          _ => SystemMouseCursors.click,
        };
      }
    } else {
      cursor = SystemMouseCursors.precise;
    }
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  /// The floating action row beside a touch/stylus selection — the
  /// affordances mice get from hover and right-click (delete, the
  /// context menu, edit-in-place). Rides above the selection, clear of
  /// the rotate knob; flips below when the selection hugs the page top.
  /// Constant size on screen at any zoom, like the rest of the chrome.
  Widget _buildSelectionChip(Rect selected) {
    final clearance = (_rotateHandleDistance + 16) * _chromeScale;
    final above =
        selected.top - clearance - 44 * _chromeScale >= 0;
    // keep the chip's body on the page near the side edges
    final width = _geometry.viewSize.width;
    final halfChip = 80 * _chromeScale;
    final anchor = Offset(
      width <= 2 * halfChip
          ? width / 2
          : selected.center.dx.clamp(halfChip, width - halfChip),
      above
          ? selected.top - clearance
          : selected.bottom + 12 * _chromeScale,
    );
    return Positioned(
      left: anchor.dx,
      top: anchor.dy,
      child: FractionalTranslation(
        translation: Offset(-0.5, above ? -1 : 0),
        child: Transform.scale(
          scale: _chromeScale,
          alignment: above ? Alignment.bottomCenter : Alignment.topCenter,
          child: Material(
            key: const ValueKey('pdf-selection-chip'),
            elevation: 3,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: const ValueKey('pdf-selection-chip-delete'),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: _controller.deleteSelected,
              ),
              if (_controller.canEditSelectedText)
                IconButton(
                  key: const ValueKey('pdf-selection-chip-edit'),
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit text',
                  onPressed: () {
                    final rect = _selectedViewRect;
                    if (rect != null) _openTextEditor(rect, existing: true);
                  },
                ),
              if (widget.onShowAnnotationMenu != null)
                IconButton(
                  key: const ValueKey('pdf-selection-chip-menu'),
                  icon: const Icon(Icons.more_horiz),
                  tooltip: 'More',
                  onPressed: () {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    widget.onShowAnnotationMenu!(box.localToGlobal(anchor));
                  },
                ),
            ]),
          ),
        ),
      ),
    );
  }

  /// The Flutter font family that visually matches [font] — the same
  /// substitution the renderer uses for non-embedded base-14 fonts.
  static String _uiFamily(PdfStandardFont font) => switch (font) {
        PdfStandardFont.helvetica => 'Helvetica',
        PdfStandardFont.times => 'Times New Roman',
        PdfStandardFont.courier => 'Courier',
      };

  @override
  Widget build(BuildContext context) {
    _ensureGhost();
    // the afterimage has served once the committed revision's raster is
    // on screen — or is stale once the document moved past that revision
    if (_afterDocument != null &&
        (widget.rasterCurrent ||
            !identical(_afterDocument, _controller.document))) {
      _clearAfterimage();
    }
    // switching tools mid-edit commits the text, like leaving the ink tool
    if (_textEditRect != null && _tool != _textEditTool) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _textEditRect != null && _tool != _textEditTool) {
          _commitTextEdit();
        }
      });
    }
    final selected = _selectedViewRect;
    final chrome = _selectionChrome;
    final restingRotation = chrome?.$2 ?? 0;
    final moveDelta =
        _resizeHandle == null && _moveStart != null && _moveCurrent != null
            ? _moveCurrent! - _moveStart!
            : Offset.zero;
    // the rest of a multi-selection on this page: chrome boxes without
    // handles, riding along with a move drag
    final allSelected = _selectedViewRects;
    final extraSelected = [
      for (final rect in selected == null
          ? allSelected
          : allSelected.sublist(0, allSelected.length - 1))
        rect.shift(moveDelta)
    ];
    final rotating = _rotateStartAngle != null;
    final dragging =
        _resizeHandle != null || moveDelta != Offset.zero || rotating;
    // strokes beyond the pending ink: the committed-ink afterimage (held
    // until the new raster lands) and the signature tool's live preview
    final committedInk = widget.rasterCurrent
        ? null
        : _controller.committedInkOn(widget.pageIndex);
    _InkPaint? signaturePreview;
    if (_signaturePreview != null && _tool == PdfEditTool.signature) {
      final (x, y) = _geometry.toPagePoint(_signaturePreview!);
      final placement =
          _controller.signaturePlacement(widget.pageIndex, x, y);
      if (placement != null) {
        signaturePreview = (
          strokes: placement.strokes,
          pressures: placement.pressures,
          color: Color(0xFF000000 | placement.color)
              .withValues(alpha: 0.55),
          strokeWidth: placement.strokeWidth * _geometry.scale,
        );
      }
    }
    final extraInk = <_InkPaint>[
      if (committedInk != null)
        (
          strokes: committedInk.strokes,
          pressures: committedInk.pressures,
          color: committedInk.color,
          strokeWidth: committedInk.strokeWidth * _geometry.scale,
        ),
      if (_afterSignature != null) _afterSignature!,
      if (signaturePreview != null) signaturePreview,
      // the eraser's live remainders, then the committed slice held
      // until its raster lands — painted over the fade wash
      ..._eraseSliced.values,
      ...?_afterEraseInk,
    ];
    // a fresh attention flash for this page starts its pulse
    final flash = _controller.pendingFlash;
    if (flash != null &&
        flash.page == widget.pageIndex &&
        flash.sequence != _flashSequence) {
      _flashSequence = flash.sequence;
      _flashRect = _controller.annotationAt(flash.page, flash.slot)?.rect;
      if (_flashRect != null) _flashController.forward(from: 0);
    }
    // warm the eyedropper's raster so the first preview is instant-ish
    if (_controller.isPickingColor) unawaited(_ensureSampler());
    final preview = _controller.isPickingColor ? _pickPosition : null;
    // touch and stylus get the hover/right-click affordances as a
    // floating action chip beside the selection
    final showChip = (_lastPointerKind == PointerDeviceKind.touch ||
            _lastPointerKind == PointerDeviceKind.stylus) &&
        _selectMode &&
        selected != null &&
        !dragging &&
        _moveStart == null &&
        _marqueeStart == null &&
        _textEditRect == null &&
        _rawPointer == null;
    return Listener(
      // raw events carry what pan callbacks drop: pressure and the
      // device kind (for Apple Pencil palm rejection); pointer-up is
      // also the eyedropper's commit
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // with finger drawing off, touch falls through to the scroll
        // view and only pen-like devices reach the ink recognizers
        supportedDevices: _drawTool && !_controller.fingerDrawsInk
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
            if (_pickPosition == null &&
                (_signaturePreview == null || _signatureDrag) &&
                (_eraserCursor == null || _erasePath.isNotEmpty)) {
              return;
            }
            setState(() {
              _pickPosition = null;
              _pickPreview = null;
              if (!_signatureDrag) _signaturePreview = null;
              if (_erasePath.isEmpty) _eraserCursor = null;
            });
          },
          child: Stack(children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _EditingPreviewPainter(
                  theme: PdfViewerTheme.of(context),
                  chromeScale: _chromeScale,
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
                      : chrome?.$1.shift(moveDelta),
                  extraSelectionRects: extraSelected,
                  marqueeRect: _marqueeStart != null && _marqueeCurrent != null
                      ? Rect.fromPoints(_marqueeStart!, _marqueeCurrent!)
                      : null,
                  ghost: _ghost,
                  ghostFrom: _resizeHandle != null && _resizeAngle != 0
                      ? _resizeFrom
                      : selected,
                  ghostTo: _resizeHandle != null
                      ? _resizeRect
                      : selected?.shift(moveDelta),
                  dragging: dragging,
                  rotation:
                      restingRotation + (rotating ? _rotateDelta : 0),
                  ghostRotation: rotating ? _rotateDelta : 0,
                  ghostLocalAngle:
                      _resizeHandle != null ? _resizeAngle : 0,
                  extraInk: extraInk,
                  fadeRects: [
                    ..._eraseRects.values,
                    ...?_afterEraseRects,
                  ],
                  fadeColor: widget.pageColor.withValues(alpha: 0.72),
                  eraserCursor: _tool == PdfEditTool.eraser || _rawErasing
                      ? _eraserCursor
                      : null,
                  eraserRadius:
                      _controller.eraserRadius * _geometry.scale,
                  afterGhost: _afterGhost != null
                      ? (
                          picture: _afterGhost!,
                          from: _afterGhostFrom!,
                          to: _afterGhostTo!,
                          rotation: _afterGhostRotation,
                          localAngle: _afterGhostLocalAngle,
                        )
                      : null,
                  afterShape: _afterShape,
                  showHandles: selected != null &&
                      _controller.canResizeSelected &&
                      _moveStart == null,
                  showRotateHandle: selected != null &&
                      _controller.canRotateSelected &&
                      _moveStart == null,
                  elementRect: _selectedElementViewRect,
                  flashRect: _flashController.isAnimating &&
                          _flashRect != null
                      ? _geometry.toViewRect(_flashRect!)
                      : null,
                  flashProgress: _flashController.value,
                ),
                size: Size.infinite,
              ),
            ),
            // a just-committed text edit, frozen until the page raster
            // catches up (same wash the inline editor painted over old
            // renderings, so nothing shows through meanwhile)
            if (_afterText case final after?)
              Positioned.fromRect(
                rect: after.rect,
                child: IgnorePointer(
                  child: Container(
                    color: after.fill ??
                        (after.washed
                            ? widget.pageColor.withValues(alpha: 0.92)
                            : null),
                    padding: EdgeInsets.all(3 * _geometry.scale),
                    alignment: Alignment.topLeft,
                    child: Text(
                      after.text,
                      style: TextStyle(
                        color: after.color,
                        fontSize: after.size * _geometry.scale,
                        height: 1.2,
                        fontFamily: _uiFamily(after.font),
                      ),
                    ),
                  ),
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
            if (_textEditRect != null)
              Positioned.fromRect(
                rect: _textEditRect!.inflate(2),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape):
                        _cancelTextEdit,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _commitTextEdit,
                    const SingleActivator(LogicalKeyboardKey.enter,
                        control: true): _commitTextEdit,
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      // the box's own fill when it has one; otherwise wash
                      // the paper color over what's underneath: faint for a
                      // fresh box, near-opaque when editing existing text
                      // so the old rendering doesn't show through
                      color: _textEditFill ??
                          widget.pageColor
                              .withValues(alpha: _textEditExisting ? 0.92 : 0.3),
                      border: Border.all(
                          color: PdfViewerTheme.of(context)
                                  .annotationChromeColor ??
                              const Color(0xFF1E88E5),
                          width: 1.5 * _chromeScale),
                    ),
                    child: TextField(
                      key: ValueKey(_textEditFieldName == null
                          ? 'pdf-freetext-editor'
                          : 'pdf-form-text-editor'),
                      controller: _textEditText,
                      focusNode: _textEditFocus,
                      autofocus: true,
                      // single-line form fields edit single-line: Enter
                      // commits instead of inserting a newline
                      maxLines: _textEditFieldName == null ||
                              _textEditMultiline
                          ? null
                          : 1,
                      expands:
                          _textEditFieldName == null || _textEditMultiline,
                      onSubmitted: (_) => _commitTextEdit(),
                      textAlignVertical: _textEditFieldName == null ||
                              _textEditMultiline
                          ? TextAlignVertical.top
                          : TextAlignVertical.center,
                      cursorColor: _textEditColor,
                      // mirrors the committed appearance: same size in view
                      // pixels, same 1.2 leading, matching family and color
                      style: TextStyle(
                        color: _textEditColor,
                        fontSize: _textEditSize * _geometry.scale,
                        height: 1.2,
                        fontFamily: _uiFamily(_textEditFont),
                      ),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(3 * _geometry.scale),
                      ),
                    ),
                  ),
                ),
              ),
            if (showChip) _buildSelectionChip(chrome?.$1 ?? selected),
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
              border: Border.all(color: Theme.of(context).colorScheme.outline),
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
    required this.theme,
    this.chromeScale = 1,
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.geometry,
    required this.strokes,
    required this.pressures,
    required this.dragRect,
    required this.selectionRect,
    required this.extraSelectionRects,
    required this.marqueeRect,
    required this.ghost,
    required this.ghostFrom,
    required this.ghostTo,
    required this.dragging,
    required this.rotation,
    required this.ghostRotation,
    this.ghostLocalAngle = 0,
    required this.extraInk,
    this.fadeRects = const [],
    this.fadeColor = const Color(0x00000000),
    this.eraserCursor,
    this.eraserRadius = 0,
    required this.afterGhost,
    required this.afterShape,
    required this.showHandles,
    required this.showRotateHandle,
    required this.elementRect,
    this.flashRect,
    this.flashProgress = 0,
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

  /// The non-primary members of a multi-selection on this page: chrome
  /// boxes without handles.
  final List<Rect> extraSelectionRects;

  /// The select tool's in-flight rubber band.
  final Rect? marqueeRect;

  /// The selected annotation's appearance in page raster space, and its
  /// resting view rect — drawn stretched onto [ghostTo] while
  /// [dragging], so the user sees the move/resize result live.
  final ui.Picture? ghost;
  final Rect? ghostFrom;
  final Rect? ghostTo;
  final bool dragging;

  /// The chrome's total rotation (view radians, clockwise positive):
  /// the annotation's resting rotation plus a rotate drag's sweep — the
  /// selection box hugs rotated artwork instead of boxing its bounds.
  final double rotation;

  /// A rotate drag's sweep alone: the ghost's appearance already carries
  /// the resting rotation, so only the delta spins it.
  final double ghostRotation;

  /// A rotated selection's resting angle during a resize drag:
  /// [ghostFrom]/[ghostTo] are then local boxes and the ghost scales
  /// along the rotated axes instead of stretching page-axis rects.
  final double ghostLocalAngle;

  /// Stroke sets beyond the pending ink: committed-ink afterimages and
  /// the signature tool's live preview.
  final List<_InkPaint> extraInk;

  /// Annotations the eraser swipe has marked: their view rects, washed
  /// with [fadeColor] (the paper color, mostly opaque) so they read as
  /// going — live during the swipe, and as the afterimage until the
  /// deletion's raster lands.
  final List<Rect> fadeRects;
  final Color fadeColor;

  /// The circle eraser's ring cursor: view position and radius (the
  /// page-space eraser radius scaled into view pixels, so the ring is
  /// exactly the area the eraser removes at any zoom).
  final Offset? eraserCursor;
  final double eraserRadius;

  /// A just-committed move/resize/rotate, kept painted at full strength
  /// until the new revision's raster lands.
  final ({
    ui.Picture picture,
    Rect from,
    Rect to,
    double rotation,
    double localAngle,
  })? afterGhost;

  /// A just-committed shape's drag preview, same deal.
  final ({Rect rect, PdfEditTool tool, Color color, double strokeWidth})?
      afterShape;

  final bool showHandles;
  final bool showRotateHandle;

  /// The selected content element's box — orange, to read as "page
  /// content", distinct from the blue annotation chrome.
  final Rect? elementRect;

  /// An attention pulse around [flashRect] (the annotation a sidebar
  /// tile zoomed to), animated by [flashProgress] 0→1: an amber ring
  /// closing in on the rect, fading as it settles.
  final Rect? flashRect;
  final double flashProgress;

  final PdfViewerThemeData theme;

  /// Overlay pixels per intended screen pixel — chrome (selection boxes,
  /// handles, marquee, flash ring) multiplies its sizes by this so it
  /// stays constant-size on screen while the viewer is zoomed in.
  final double chromeScale;

  Color get _chrome =>
      theme.annotationChromeColor ?? const Color(0xFF1E88E5);
  Color get _elementChrome =>
      theme.elementChromeColor ?? const Color(0xFFFB8C00);
  Color get _flash => theme.flashColor ?? const Color(0xFFFFB300);

  /// Paints one set of page-space ink strokes with the committed
  /// appearance's smoothing and pressure mapping.
  void _paintInk(
      Canvas canvas,
      List<List<(double, double)>> strokes,
      List<List<double>?> pressures,
      Color color,
      double strokeWidth) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var s = 0; s < strokes.length; s++) {
      final stroke = strokes[s];
      final pressure = s < pressures.length ? pressures[s] : null;
      if (stroke.isEmpty) continue;
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
  }

  void _paintShapePreview(
      Canvas canvas, Rect rect, PdfEditTool? tool, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (tool) {
      case PdfEditTool.ellipse:
        canvas.drawOval(rect, paint);
      case PdfEditTool.freeText || PdfEditTool.stamp || PdfEditTool.form:
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

  @override
  void paint(Canvas canvas, Size size) {
    // the wash goes under every stroke preview: the eraser's sliced
    // remainders (and any other pending ink) paint at full strength
    // over their faded originals
    if (fadeRects.isNotEmpty) {
      final wash = Paint()..color = fadeColor;
      for (final rect in fadeRects) {
        canvas.drawRect(rect.inflate(2), wash);
      }
    }

    _paintInk(canvas, strokes, pressures, color, strokeWidth);
    for (final ink in extraInk) {
      _paintInk(canvas, ink.strokes, ink.pressures, ink.color,
          ink.strokeWidth);
    }

    final after = afterShape;
    if (after != null) {
      _paintShapePreview(
          canvas, after.rect, after.tool, after.color, after.strokeWidth);
    }

    final rect = dragRect;
    if (rect != null) {
      _paintShapePreview(canvas, rect, tool, color, strokeWidth);
    }

    for (final rect in extraSelectionRects) {
      final box = rect.inflate(2 * chromeScale);
      canvas.drawRect(box, Paint()..color = _chrome.withAlpha(0x1A));
      canvas.drawRect(
          box,
          Paint()
            ..color = _chrome
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * chromeScale);
    }

    final marquee = marqueeRect;
    if (marquee != null) {
      canvas.drawRect(marquee, Paint()..color = _chrome.withAlpha(0x14));
      canvas.drawRect(
          marquee,
          Paint()
            ..color = _chrome
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 * chromeScale);
    }

    final committed = afterGhost;
    if (committed != null) {
      // full strength: this *is* the committed result, standing in for
      // the raster that hasn't landed yet
      paintAnnotationDragPreview(canvas,
          picture: committed.picture,
          from: committed.from,
          to: committed.to,
          scale: geometry.scale,
          rotation: committed.rotation,
          localAngle: committed.localAngle,
          opacity: 1);
    }

    final selection = selectionRect;
    final ghost = this.ghost;
    final ghostFrom = this.ghostFrom;
    final ghostTo = this.ghostTo;
    if (dragging && ghostTo != null && ghost != null && ghostFrom != null) {
      paintAnnotationDragPreview(canvas,
          picture: ghost,
          from: ghostFrom,
          to: ghostTo,
          scale: geometry.scale,
          rotation: ghostRotation,
          localAngle: ghostLocalAngle);
    }
    if (selection != null) {
      canvas.save();
      if (rotation != 0) {
        canvas.translate(selection.center.dx, selection.center.dy);
        canvas.rotate(rotation);
        canvas.translate(-selection.center.dx, -selection.center.dy);
      }
      final box = selection.inflate(2 * chromeScale);
      final stroke = Paint()
        ..color = _chrome
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * chromeScale;
      canvas.drawRect(box, Paint()..color = _chrome.withAlpha(0x1A));
      canvas.drawRect(box, stroke);
      // the knob's connector line first, so the top-center resize handle
      // paints over it instead of being crossed out
      final rotateKnob = showRotateHandle
          ? Offset(box.center.dx,
              box.top - (_rotateHandleDistance - 2) * chromeScale)
          : null;
      if (rotateKnob != null) {
        canvas.drawLine(box.topCenter, rotateKnob, stroke);
      }
      if (showHandles) {
        final fill = Paint()..color = const Color(0xFFFFFFFF);
        for (final handle in _handles) {
          final center = Offset(
            box.center.dx + handle.dx * box.width / 2,
            box.center.dy + handle.dy * box.height / 2,
          );
          final knob = Rect.fromCircle(
              center: center, radius: _handleSize / 2 * chromeScale);
          canvas.drawRect(knob, fill);
          canvas.drawRect(knob, stroke);
        }
      }
      if (rotateKnob != null) {
        canvas.drawCircle(rotateKnob, (_handleSize / 2 + 1) * chromeScale,
            Paint()..color = const Color(0xFFFFFFFF));
        canvas.drawCircle(
            rotateKnob, (_handleSize / 2 + 1) * chromeScale, stroke);
      }
      canvas.restore();
    }

    final element = elementRect;
    if (element != null) {
      final box = element.inflate(2 * chromeScale);
      canvas.drawRect(box, Paint()..color = _elementChrome.withAlpha(0x1A));
      canvas.drawRect(
          box,
          Paint()
            ..color = _elementChrome
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * chromeScale);
    }

    final flash = flashRect;
    if (flash != null) {
      final fade = (1 - flashProgress).clamp(0.0, 1.0);
      // close in over the first third, then hold while fading out
      final settle =
          Curves.easeOutCubic.transform((flashProgress * 3).clamp(0.0, 1.0));
      final ring = RRect.fromRectAndRadius(
          flash.inflate((4 + 26 * (1 - settle)) * chromeScale),
          Radius.circular(6 * chromeScale));
      canvas.drawRRect(
          ring, Paint()..color = _flash.withValues(alpha: 0.20 * fade));
      canvas.drawRRect(
          ring,
          Paint()
            ..color = _flash.withValues(alpha: 0.9 * fade)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * chromeScale);
    }

    // the eraser's ring cursor, topmost: page-space radius (it shows
    // exactly what a stamp removes), screen-constant line weight — a
    // light ring over a dark halo so it reads on any page color
    final cursor = eraserCursor;
    if (cursor != null && eraserRadius > 0) {
      canvas.drawCircle(
          cursor, eraserRadius, Paint()..color = const Color(0x14000000));
      canvas.drawCircle(
          cursor,
          eraserRadius,
          Paint()
            ..color = const Color(0x66000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * chromeScale);
      canvas.drawCircle(
          cursor,
          eraserRadius,
          Paint()
            ..color = const Color(0xFFFFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * chromeScale);
    }
  }

  /// Cheap inequality for the extra ink sets: counts plus each set's
  /// first point catch both new sets and a moving signature preview.
  static bool _inkChanged(List<_InkPaint> a, List<_InkPaint> b) {
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i].strokes.length != b[i].strokes.length ||
          a[i].color != b[i].color ||
          a[i].strokeWidth != b[i].strokeWidth) {
        return true;
      }
      if (a[i].strokes.isNotEmpty &&
          b[i].strokes.isNotEmpty &&
          (a[i].strokes.first.isEmpty != b[i].strokes.first.isEmpty ||
              (a[i].strokes.first.isNotEmpty &&
                  a[i].strokes.first.first != b[i].strokes.first.first))) {
        return true;
      }
    }
    return false;
  }

  @override
  bool shouldRepaint(_EditingPreviewPainter oldDelegate) =>
      oldDelegate.theme != theme ||
      oldDelegate.chromeScale != chromeScale ||
      oldDelegate.tool != tool ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.dragRect != dragRect ||
      oldDelegate.selectionRect != selectionRect ||
      !listEquals(oldDelegate.extraSelectionRects, extraSelectionRects) ||
      oldDelegate.marqueeRect != marqueeRect ||
      oldDelegate.ghost != ghost ||
      oldDelegate.ghostFrom != ghostFrom ||
      oldDelegate.ghostTo != ghostTo ||
      oldDelegate.dragging != dragging ||
      oldDelegate.rotation != rotation ||
      oldDelegate.ghostRotation != ghostRotation ||
      oldDelegate.ghostLocalAngle != ghostLocalAngle ||
      _inkChanged(oldDelegate.extraInk, extraInk) ||
      !listEquals(oldDelegate.fadeRects, fadeRects) ||
      oldDelegate.fadeColor != fadeColor ||
      oldDelegate.eraserCursor != eraserCursor ||
      oldDelegate.eraserRadius != eraserRadius ||
      oldDelegate.afterGhost != afterGhost ||
      oldDelegate.afterShape != afterShape ||
      oldDelegate.showHandles != showHandles ||
      oldDelegate.showRotateHandle != showRotateHandle ||
      oldDelegate.elementRect != elementRect ||
      oldDelegate.flashRect != flashRect ||
      oldDelegate.flashProgress != flashProgress ||
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
/// Drawn at ~75% [opacity] by default: solid enough to judge the
/// result, light enough to read as a preview over the still-rendered
/// original. The post-commit afterimage paints at 1.0 — it *is* the
/// committed result, standing in until the new raster lands.
///
/// [rotation] (view radians, clockwise positive) additionally spins the
/// preview about [to]'s center — the rotate handle's live feedback.
///
/// With [localAngle] (a rotated selection's resting angle), [from] and
/// [to] are *local* boxes: the picture scales by their size ratio along
/// the rotated axes about the box centers, instead of stretching one
/// page-axis rect onto another — a rotated annotation's resize preview
/// must not shear.
@visibleForTesting
void paintAnnotationDragPreview(
  Canvas canvas, {
  required ui.Picture picture,
  required Rect from,
  required Rect to,
  required double scale,
  double rotation = 0,
  double localAngle = 0,
  double opacity = 0.75,
}) {
  if (from.width <= 0 || from.height <= 0) return;
  final bounds = rotation == 0 && localAngle == 0
      ? to.inflate(4)
      : Rect.fromCircle(
          center: to.center,
          radius: Offset(to.width, to.height).distance / 2 + 4);
  canvas.saveLayer(
      bounds,
      Paint()
        ..color = const Color(0xFFFFFFFF)
            .withValues(alpha: opacity.clamp(0.0, 1.0)));
  if (rotation != 0) {
    canvas.translate(to.center.dx, to.center.dy);
    canvas.rotate(rotation);
    canvas.translate(-to.center.dx, -to.center.dy);
  }
  if (localAngle != 0) {
    canvas.translate(to.center.dx, to.center.dy);
    canvas.rotate(localAngle);
    canvas.scale(to.width / from.width, to.height / from.height);
    canvas.rotate(-localAngle);
    canvas.translate(-from.center.dx, -from.center.dy);
  } else {
    canvas.translate(to.left, to.top);
    canvas.scale(to.width / from.width, to.height / from.height);
    canvas.translate(-from.left, -from.top);
  }
  canvas.scale(scale, scale);
  canvas.drawPicture(picture);
  canvas.restore();
}
