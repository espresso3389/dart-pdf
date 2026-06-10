import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

import 'pdf_page_view.dart';

/// Drives a [PdfViewer] and reports its state: current page, zoom, and
/// search results. Listeners fire on any change.
class PdfViewerController extends ChangeNotifier {
  _PdfViewerState? _state;

  int _pageCount = 0;
  int _currentPage = 0;
  bool _searching = false;
  String _query = '';
  List<PdfTextMatch> _matches = const [];
  int _currentMatch = -1;

  int get pageCount => _pageCount;

  /// Zero-based index of the page nearest the viewport center.
  int get currentPage => _currentPage;

  bool get isSearching => _searching;
  String get query => _query;
  int get matchCount => _matches.length;

  String _selectedText = '';

  /// The currently selected text, '' with no selection. Drag with a mouse
  /// (or any pointer the platform doesn't use for scrolling) to select.
  String get selectedText => _selectedText;

  bool get hasSelection => _selectedText.isNotEmpty;

  /// Copies the current selection to the system clipboard. Also bound to
  /// Cmd/Ctrl+C while the viewer has focus.
  Future<void> copySelection() async {
    if (_selectedText.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _selectedText));
  }

  void clearSelection() => _state?._clearSelection();

  void _setSelection(String text) {
    if (text == _selectedText) return;
    _selectedText = text;
    _notifySafely();
  }

  /// Zero-based index into the matches, or -1 with no active match.
  int get currentMatch => _currentMatch;

  Future<void> jumpToPage(int index) async => _state?._jumpToPage(index);

  /// Searches the whole document and jumps to the first hit.
  Future<void> search(String query) async {
    final state = _state;
    if (state == null) return;
    _query = query;
    _matches = const [];
    _currentMatch = -1;
    _searching = query.isNotEmpty;
    notifyListeners();
    if (query.isEmpty) return;
    final matches = await state._searchAllPages(query);
    if (_query != query) return; // superseded by a newer search
    _matches = matches;
    _searching = false;
    _currentMatch = matches.isEmpty ? -1 : 0;
    notifyListeners();
    if (matches.isNotEmpty) state._showMatch(matches[0]);
  }

  void nextMatch() => _stepMatch(1);

  void previousMatch() => _stepMatch(-1);

  void clearSearch() {
    _query = '';
    _matches = const [];
    _currentMatch = -1;
    _searching = false;
    _notifySafely();
  }

  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch + delta) % _matches.length;
    if (_currentMatch < 0) _currentMatch += _matches.length;
    notifyListeners();
    _state?._showMatch(_matches[_currentMatch]);
  }

  void _setCurrentPage(int page) {
    if (page == _currentPage) return;
    _currentPage = page;
    _notifySafely();
  }

  void _setPageCount(int count) {
    _pageCount = count;
    _currentPage = 0;
    _notifySafely();
  }

  /// Viewer-internal updates can land mid-frame (initState/didUpdateWidget
  /// run during build; scroll listeners can fire during layout), when
  /// notifying would mark listening widgets dirty illegally — defer those
  /// to after the frame.
  void _notifySafely() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_state != null) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  List<PdfTextMatch> _matchesOn(int pageIndex) =>
      [for (final m in _matches) if (m.pageIndex == pageIndex) m];
}

/// A scrolling, zoomable PDF viewer.
///
/// Supports pinch zoom, double-tap zoom toggle, page tracking, and document
/// search with highlights. Pages re-rasterize at the device pixel ratio;
/// tile-based re-rendering at deep zoom is a TODO.
class PdfViewer extends StatefulWidget {
  const PdfViewer({
    super.key,
    required this.document,
    this.controller,
    this.pageSpacing = 12,
    this.maxZoom = 6,
    this.doubleTapZoom = 2.5,
  });

  final PdfDocument document;
  final PdfViewerController? controller;
  final double pageSpacing;
  final double maxZoom;
  final double doubleTapZoom;

  @override
  State<PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<PdfViewer>
    with SingleTickerProviderStateMixin {
  late PdfViewerController _controller;
  bool _ownsController = false;

  final _scroll = ScrollController();
  final _transform = TransformationController();
  late final AnimationController _zoomAnimator;
  Animation<Matrix4>? _zoomAnimation;
  TapDownDetails? _doubleTapDetails;
  bool _zoomed = false;

  /// Resolution multiplier pages render at; follows the zoom level once it
  /// settles (pinch end, wheel pause, double-tap animation end).
  double _renderScale = 1;
  Timer? _settleTimer;

  late List<PdfPage> _pages;
  late List<double> _aspects; // height / width, after /Rotate
  final Map<int, PdfPageText> _textCache = {};
  double _viewWidth = 0;

  final _focusNode = FocusNode(debugLabel: 'PdfViewer');

  // text selection: (pageIndex, offset into that page's text)
  (int, int)? _selAnchor;
  (int, int)? _selFocus;
  MouseCursor _hoverCursor = MouseCursor.defer;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? PdfViewerController();
    _ownsController = widget.controller == null;
    _controller._state = this;
    _zoomAnimator =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
          ..addListener(() {
            final animation = _zoomAnimation;
            if (animation != null) _transform.value = animation.value;
          });
    _loadPages();
    _scroll.addListener(_onScroll);
    _transform.addListener(_onTransformChanged);
  }

  /// During a gesture the existing rasters scale under the transform
  /// (cheap, momentarily blurry); once the matrix stops changing for a
  /// beat, visible pages re-rasterize sharp at the new zoom. A matrix
  /// listener (rather than onInteractionEnd) also catches wheel zoom and
  /// the double-tap animation.
  void _onTransformChanged() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      final target = math.max(1.0, _transform.value.getMaxScaleOnAxis());
      if ((target - _renderScale).abs() > 0.1 * _renderScale) {
        setState(() => _renderScale = target);
      }
    });
  }

  @override
  void didUpdateWidget(PdfViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _textCache.clear();
      _controller.clearSearch();
      _clearSelection();
      _loadPages();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _transform.value = Matrix4.identity();
      setState(() {});
    }
  }

  void _loadPages() {
    final count = widget.document.pageCount;
    _pages = [for (var i = 0; i < count; i++) widget.document.page(i)];
    _aspects = [
      for (final page in _pages)
        _isRotatedSideways(page)
            ? page.cropBox.width / math.max(1e-6, page.cropBox.height)
            : page.cropBox.height / math.max(1e-6, page.cropBox.width),
    ];
    _controller._setPageCount(count);
  }

  static bool _isRotatedSideways(PdfPage page) =>
      page.rotation == 90 || page.rotation == 270;

  @override
  void dispose() {
    _settleTimer?.cancel();
    _controller._state = null;
    if (_ownsController) _controller.dispose();
    _scroll.dispose();
    _transform.dispose();
    _zoomAnimator.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  double _pageHeight(int index) => _aspects[index] * _viewWidth;

  double _pageOffset(int index) {
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _pageHeight(i) + widget.pageSpacing;
    }
    return offset;
  }

  void _onScroll() {
    if (_viewWidth <= 0 || !_scroll.hasClients) return;
    final center =
        _scroll.offset + _scroll.position.viewportDimension / 2;
    var offset = 0.0;
    for (var i = 0; i < _pages.length; i++) {
      offset += _pageHeight(i) + widget.pageSpacing;
      if (center < offset) {
        _controller._setCurrentPage(i);
        return;
      }
    }
    _controller._setCurrentPage(_pages.length - 1);
  }

  Future<void> _jumpToPage(int index) async {
    if (!_scroll.hasClients) return;
    final target = _pageOffset(index.clamp(0, _pages.length - 1));
    await _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  Future<List<PdfTextMatch>> _searchAllPages(String query) async {
    final matches = <PdfTextMatch>[];
    for (var i = 0; i < _pages.length; i++) {
      final text = _textCache[i] ??=
          PdfTextExtractor.extract(widget.document, i);
      matches.addAll(text.findAll(query));
      // yield between pages so long documents don't freeze the UI
      if (i % 5 == 4) await Future<void>.delayed(Duration.zero);
    }
    return matches;
  }

  PdfPageText _pageText(int index) =>
      _textCache[index] ??= PdfTextExtractor.extract(widget.document, index);

  /// Maps a pointer position (list coordinates, inside the
  /// InteractiveViewer transform) to a text position. [tolerance] is in
  /// page units; pass infinity to snap to the nearest text while dragging.
  (int, int)? _textPositionAt(Offset local, {required double tolerance}) {
    if (_viewWidth <= 0 || !_scroll.hasClients || _pages.isEmpty) return null;
    final contentY = _scroll.offset + local.dy;
    var top = 0.0;
    for (var i = 0; i < _pages.length; i++) {
      final height = _pageHeight(i);
      if (contentY <= top + height || i == _pages.length - 1) {
        final box = _pages[i].cropBox;
        if (box.width <= 0) return null;
        // TODO: selection on /Rotate'd pages needs the rotation transform
        final scale = _viewWidth / box.width;
        final x = box.left + local.dx / scale;
        final y = box.top - (contentY - top) / scale;
        final offset = _pageText(i).positionNear(x, y, tolerance: tolerance);
        return offset < 0 ? null : (i, offset);
      }
      top += height + widget.pageSpacing;
    }
    return null;
  }

  void _onHover(PointerHoverEvent event) {
    final overText =
        _textPositionAt(event.localPosition, tolerance: 8) != null;
    final cursor = overText ? SystemMouseCursors.text : MouseCursor.defer;
    if (cursor != _hoverCursor) setState(() => _hoverCursor = cursor);
  }

  void _onSelectionStart(DragStartDetails details) {
    _focusNode.requestFocus();
    final position =
        _textPositionAt(details.localPosition, tolerance: 14);
    setState(() {
      _selAnchor = position;
      _selFocus = position;
    });
    _controller._setSelection('');
  }

  void _onSelectionUpdate(DragUpdateDetails details) {
    if (_selAnchor == null) return;
    final position = _textPositionAt(details.localPosition,
        tolerance: double.infinity);
    if (position == null || position == _selFocus) return;
    setState(() => _selFocus = position);
    _controller._setSelection(_selectedText());
  }

  void _clearSelection() {
    if (_selAnchor != null || _selFocus != null) {
      setState(() {
        _selAnchor = null;
        _selFocus = null;
      });
    }
    _controller._setSelection('');
  }

  /// Selection bounds in document order, or null when empty.
  ((int, int), (int, int))? get _selRange {
    final a = _selAnchor, f = _selFocus;
    if (a == null || f == null || a == f) return null;
    final reversed = f.$1 < a.$1 || (f.$1 == a.$1 && f.$2 < a.$2);
    return reversed ? (f, a) : (a, f);
  }

  String _selectedText() {
    final range = _selRange;
    if (range == null) return '';
    final (start, end) = range;
    final parts = <String>[];
    for (var i = start.$1; i <= end.$1; i++) {
      final text = _pageText(i).text;
      final from = (i == start.$1 ? start.$2 : 0).clamp(0, text.length);
      final to = (i == end.$1 ? end.$2 : text.length).clamp(0, text.length);
      if (from < to) parts.add(text.substring(from, to));
    }
    return parts.join('\n');
  }

  List<PdfRect> _selectionRectsOn(int pageIndex) {
    final range = _selRange;
    if (range == null) return const [];
    final (start, end) = range;
    if (pageIndex < start.$1 || pageIndex > end.$1) return const [];
    final text = _pageText(pageIndex);
    final from = pageIndex == start.$1 ? start.$2 : 0;
    final to = pageIndex == end.$1 ? end.$2 : text.text.length;
    if (from >= to) return const [];
    return text.rectsFor(from, to);
  }

  void _showMatch(PdfTextMatch match) {
    if (!_scroll.hasClients || _viewWidth <= 0) return;
    final page = _pages[match.pageIndex];
    final box = page.cropBox;
    var target = _pageOffset(match.pageIndex);
    if (match.rects.isNotEmpty && box.height > 0) {
      // place the match a third of the way down the viewport
      final fractionDown = (box.top - match.rects.first.top) / box.height;
      target += fractionDown * _pageHeight(match.pageIndex) -
          _scroll.position.viewportDimension / 3;
    }
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
    setState(() {}); // repaint highlights with the new current match
  }

  void _onDoubleTap() {
    final details = _doubleTapDetails;
    if (details == null) return;
    final Matrix4 end;
    if (_zoomed) {
      end = Matrix4.identity();
    } else {
      final position = details.localPosition;
      final scale = widget.doubleTapZoom;
      end = Matrix4.identity()
        ..translateByDouble(-position.dx * (scale - 1),
            -position.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    _zoomAnimation = Matrix4Tween(begin: _transform.value, end: end).animate(
        CurvedAnimation(parent: _zoomAnimator, curve: Curves.easeInOut));
    _zoomAnimator.forward(from: 0);
    setState(() => _zoomed = !_zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _viewWidth = constraints.maxWidth;
      final list = ListView.builder(
        controller: _scroll,
        itemCount: _pages.length,
        padding: EdgeInsets.only(bottom: widget.pageSpacing),
        itemBuilder: (context, index) => Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : widget.pageSpacing),
          child: _PdfViewerPage(
            page: _pages[index],
            scale: _renderScale,
            matches: _controller._matchesOn(index),
            currentMatch: _controller._currentMatch >= 0
                ? _controller._matches[_controller._currentMatch]
                : null,
            selection: _selectionRectsOn(index),
          ),
        ),
      );
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
              _controller.copySelection,
          const SingleActivator(LogicalKeyboardKey.keyC, control: true):
              _controller.copySelection,
          const SingleActivator(LogicalKeyboardKey.escape): _clearSelection,
        },
        child: Focus(
          focusNode: _focusNode,
          child: GestureDetector(
            onDoubleTapDown: (details) => _doubleTapDetails = details,
            onDoubleTap: _onDoubleTap,
            child: InteractiveViewer(
              transformationController: _transform,
              maxScale: widget.maxZoom,
              minScale: 1,
              // vertical drags scroll the list; horizontal panning engages
              // once zoomed in
              panEnabled: _zoomed,
              onInteractionEnd: (_) {
                final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
                if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
              },
              // selection drags: scroll wheels and touch scrolling go to
              // the list (its drag recognizers win the arena for touch);
              // mouse drags fall through to this detector
              child: MouseRegion(
                cursor: _hoverCursor,
                onHover: _onHover,
                onExit: (_) {
                  if (_hoverCursor != MouseCursor.defer) {
                    setState(() => _hoverCursor = MouseCursor.defer);
                  }
                },
                child: GestureDetector(
                  onTap: _clearSelection,
                  onPanStart: _onSelectionStart,
                  onPanUpdate: _onSelectionUpdate,
                  child: ColoredBox(
                    color: const Color(0xFF404347),
                    child: list,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _PdfViewerPage extends StatelessWidget {
  const _PdfViewerPage({
    required this.page,
    required this.scale,
    required this.matches,
    required this.currentMatch,
    required this.selection,
  });

  final PdfPage page;
  final double scale;
  final List<PdfTextMatch> matches;
  final PdfTextMatch? currentMatch;
  final List<PdfRect> selection;

  @override
  Widget build(BuildContext context) {
    // the Stack is always present — toggling it when highlights appear
    // would reshape the element tree and recreate PdfPageView's state
    // (dropping its rendered image: a white flash)
    return Stack(children: [
      PdfPageView(page: page, scale: scale),
      Positioned.fill(
        child: CustomPaint(
          painter: _HighlightPainter(
            box: page.cropBox,
            matches: matches,
            currentMatch: currentMatch,
            selection: selection,
          ),
        ),
      ),
    ]);
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.box,
    required this.matches,
    required this.currentMatch,
    required this.selection,
  });

  final PdfRect box;
  final List<PdfTextMatch> matches;
  final PdfTextMatch? currentMatch;
  final List<PdfRect> selection;

  @override
  void paint(Canvas canvas, Size size) {
    if (box.width <= 0 || box.height <= 0) return;
    // TODO: highlights on /Rotate'd pages need the rotation transform
    final scale = size.width / box.width;
    final selected = Paint()..color = const Color(0x4D2196F3);
    for (final rect in selection) {
      canvas.drawRect(_toViewRect(rect, scale), selected);
    }
    final normal = Paint()..color = const Color(0x66FFEB3B);
    final current = Paint()..color = const Color(0x88FF9800);
    for (final match in matches) {
      final paint = identical(match, currentMatch) ? current : normal;
      for (final rect in match.rects) {
        canvas.drawRect(_toViewRect(rect, scale), paint);
      }
    }
  }

  Rect _toViewRect(PdfRect rect, double scale) => Rect.fromLTRB(
        (rect.left - box.left) * scale,
        (box.top - rect.top) * scale,
        (rect.right - box.left) * scale,
        (box.top - rect.bottom) * scale,
      );

  @override
  bool shouldRepaint(_HighlightPainter oldDelegate) =>
      oldDelegate.matches != matches ||
      oldDelegate.currentMatch != currentMatch ||
      oldDelegate.selection != selection;
}
