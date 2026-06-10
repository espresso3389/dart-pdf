import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import '../pdf_viewer.dart';
import '../renderer.dart';
import 'editing_controller.dart';

/// A panel of page thumbnails: tap one to jump there, drag a tile up or
/// down to reorder pages (with a mouse just drag; on touch, long-press
/// first so the list still scrolls), and the footer button deletes a
/// page (the last remaining page cannot be deleted).
///
/// Thumbnails replay each page's recorded display list, so they stay
/// sharp at any width and re-render on every revision — including undo
/// and redo. The current page is outlined, and the part of the document
/// inside the viewer's viewport is marked on the thumbnails it touches.
///
/// Place it beside the viewer, typically in a [Row]:
///
/// ```dart
/// Row(children: [
///   PdfThumbnailSidebar(
///     controller: editing,
///     viewerController: viewerController,
///   ),
///   Expanded(child: PdfViewer(...)),
/// ])
/// ```
class PdfThumbnailSidebar extends StatelessWidget {
  const PdfThumbnailSidebar({
    super.key,
    required this.controller,
    required this.viewerController,
    this.width = 160,
  });

  final PdfEditingController controller;

  /// The viewer to navigate when a thumbnail is tapped.
  final PdfViewerController viewerController;

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            controller,
            viewerController,
            viewerController.viewportChanges,
          ]),
          builder: (context, _) => ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: controller.document.pageCount,
            onReorderItem: controller.movePage,
            itemBuilder: (context, index) => _ReorderDragStartListener(
              key: ValueKey(index),
              index: index,
              child: _PageTile(
                controller: controller,
                viewerController: viewerController,
                pageIndex: index,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Starts a tile drag immediately for mouse pointers (the desktop
/// expectation — a mouse drag never means scrolling) but only after a
/// long press for touch and stylus, so finger drags still scroll the
/// list. Plain taps are unaffected either way: both recognizers claim
/// the pointer only once it moves past the slop.
class _ReorderDragStartListener extends ReorderableDragStartListener {
  const _ReorderDragStartListener({
    super.key,
    required super.index,
    required super.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        SliverReorderableList.maybeOf(context)?.startItemDragReorder(
          index: index,
          event: event,
          recognizer: (event.kind == PointerDeviceKind.mouse
              ? ImmediateMultiDragGestureRecognizer(debugOwner: this)
              : DelayedMultiDragGestureRecognizer(debugOwner: this))
            ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context),
        );
      },
      child: child,
    );
  }
}

/// One page's thumbnail with its "Page N" / delete footer.
class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.controller,
    required this.viewerController,
    required this.pageIndex,
  });

  final PdfEditingController controller;
  final PdfViewerController viewerController;
  final int pageIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final document = controller.document;
    final current = viewerController.currentPage == pageIndex;
    final viewport = viewerController.visiblePageRegion(pageIndex);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(viewerController.jumpToPage(pageIndex)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: current ? scheme.primary : scheme.outlineVariant,
                  width: current ? 2 : 1,
                ),
              ),
              child: Stack(children: [
                // the boundary keeps scroll-driven indicator repaints
                // from replaying the page picture
                RepaintBoundary(
                  child:
                      _PageThumbnail(document: document, pageIndex: pageIndex),
                ),
                if (viewport != null)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ViewportPainter(viewport, scheme.primary),
                    ),
                  ),
              ]),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text('Page ${pageIndex + 1}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium),
                ),
                if (document.pageCount > 1)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    tooltip: 'Delete page',
                    style: IconButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(28, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => controller.removePage(pageIndex),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a page's display list scaled down to the tile width.
class _PageThumbnail extends StatefulWidget {
  const _PageThumbnail({required this.document, required this.pageIndex});

  final PdfDocument document;
  final int pageIndex;

  @override
  State<_PageThumbnail> createState() => _PageThumbnailState();
}

class _PageThumbnailState extends State<_PageThumbnail> {
  ui.Picture? _picture;
  Size _pictureSize = Size.zero;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void didUpdateWidget(_PageThumbnail old) {
    super.didUpdateWidget(old);
    // the document changes identity on every revision
    if (!identical(old.document, widget.document) ||
        old.pageIndex != widget.pageIndex) {
      _render();
    }
  }

  @override
  void dispose() {
    _generation++; // orphan any render still in flight
    _picture?.dispose();
    super.dispose();
  }

  void _render() {
    final generation = ++_generation;
    final page = widget.document.page(widget.pageIndex);
    final size = PdfPageRenderer.pageSize(page);
    unawaited(PdfPageRenderer.renderPicture(page).then((picture) {
      if (generation != _generation) {
        picture.dispose();
        return;
      }
      setState(() {
        _picture?.dispose();
        _picture = picture;
        _pictureSize = size;
      });
      // a page the main viewer fails on just keeps the blank placeholder
    }, onError: (Object _, StackTrace __) {}));
  }

  @override
  Widget build(BuildContext context) {
    // sized from the current page; the painted picture may briefly be
    // the previous revision's while the new render is in flight
    final size =
        PdfPageRenderer.pageSize(widget.document.page(widget.pageIndex));
    return AspectRatio(
      aspectRatio: size.width / size.height,
      child: _picture == null
          ? const ColoredBox(color: Color(0xFFFFFFFF))
          : CustomPaint(painter: _ThumbnailPainter(_picture!, _pictureSize)),
    );
  }
}

/// Marks the viewer's viewport on a thumbnail: [region] is the visible
/// part of the page as fractions of its area.
class _ViewportPainter extends CustomPainter {
  const _ViewportPainter(this.region, this.color);

  final Rect region;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      region.left * size.width,
      region.top * size.height,
      region.right * size.width,
      region.bottom * size.height,
    );
    canvas
      ..drawRect(rect, Paint()..color = color.withValues(alpha: 0.10))
      ..drawRect(
          rect.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color);
  }

  @override
  bool shouldRepaint(_ViewportPainter old) =>
      old.region != region || old.color != color;
}

class _ThumbnailPainter extends CustomPainter {
  const _ThumbnailPainter(this.picture, this.pageSize);

  final ui.Picture picture;
  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageSize.isEmpty) return;
    canvas
      ..clipRect(Offset.zero & size)
      ..scale(
          math.min(size.width / pageSize.width, size.height / pageSize.height))
      ..drawPicture(picture);
  }

  @override
  bool shouldRepaint(_ThumbnailPainter old) =>
      old.picture != picture || old.pageSize != pageSize;
}
