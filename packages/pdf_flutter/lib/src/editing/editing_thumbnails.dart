import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import '../pdf_viewer.dart';
import '../renderer.dart';
import 'editing_controller.dart';

/// A panel of page thumbnails: tap one to jump there, long-press and
/// drag to reorder pages, and the footer button deletes a page (the
/// last remaining page cannot be deleted).
///
/// Thumbnails replay each page's recorded display list, so they stay
/// sharp at any width and re-render on every revision — including undo
/// and redo. The current page is outlined.
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
          listenable: Listenable.merge([controller, viewerController]),
          builder: (context, _) => ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: controller.document.pageCount,
            onReorderItem: controller.movePage,
            itemBuilder: (context, index) =>
                ReorderableDelayedDragStartListener(
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
              child: _PageThumbnail(document: document, pageIndex: pageIndex),
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

class _ThumbnailPainter extends CustomPainter {
  const _ThumbnailPainter(this.picture, this.pageSize);

  final ui.Picture picture;
  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageSize.isEmpty) return;
    canvas
      ..clipRect(Offset.zero & size)
      ..scale(math.min(
          size.width / pageSize.width, size.height / pageSize.height))
      ..drawPicture(picture);
  }

  @override
  bool shouldRepaint(_ThumbnailPainter old) =>
      old.picture != picture || old.pageSize != pageSize;
}
