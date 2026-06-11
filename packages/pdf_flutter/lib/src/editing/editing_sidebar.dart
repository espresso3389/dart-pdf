import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import '../pdf_viewer.dart';
import '../scrollbar.dart';
import 'editing_controller.dart';
import 'editing_panel.dart';
import 'editing_preferences.dart';

/// A panel listing every annotation in the document, grouped by page,
/// each tile showing its author (/T) when the annotation carries one.
///
/// Tapping a tile zooms the viewer to the annotation, selects it
/// (arming the select tool), and pulses an attention flash around it on
/// the page; the trailing button deletes it. A long press starts
/// multi-select: checkboxes replace the icons, tapping toggles, and the
/// header's delete removes everything checked as one undo step. The
/// list rebuilds on every revision, so it always reflects the current
/// state — including undo and redo.
///
/// The inner edge is draggable ([resizable]); the chosen width persists
/// via [PdfEditingPreferences.annotationSidebarWidth].
///
/// Place it beside the viewer, typically in a [Row]:
///
/// ```dart
/// Row(children: [
///   Expanded(child: PdfViewer(...)),
///   PdfAnnotationSidebar(
///     controller: editing,
///     viewerController: viewerController,
///   ),
/// ])
/// ```
class PdfAnnotationSidebar extends StatefulWidget {
  const PdfAnnotationSidebar({
    super.key,
    required this.controller,
    required this.viewerController,
    this.width = 280,
    this.side = PdfSidebarSide.right,
    this.resizable = true,
    this.minWidth = 200,
    this.maxWidth = 480,
  });

  final PdfEditingController controller;

  /// The viewer to navigate when a tile is tapped.
  final PdfViewerController viewerController;

  /// The default width — a user-dragged width, persisted in
  /// [PdfEditingPreferences.annotationSidebarWidth], wins over it.
  final double width;

  /// Which side of the viewer the panel sits on; the resize grip rides
  /// the opposite (inner) edge.
  final PdfSidebarSide side;

  /// Whether the inner edge can be dragged to resize the panel.
  final bool resizable;

  /// Clamps for the dragged width.
  final double minWidth;
  final double maxWidth;

  @override
  State<PdfAnnotationSidebar> createState() => _PdfAnnotationSidebarState();
}

class _PdfAnnotationSidebarState extends State<PdfAnnotationSidebar> {
  /// Links and form fields are listed but not selectable (the select
  /// tool refuses them too); popups belong to their parent annotation
  /// and are not listed at all.
  static const _unlisted = {'Popup'};
  static const _unselectable = {'Link', 'Widget'};

  /// Checked tiles in multi-select mode, as (page, /Annots slot).
  final Set<(int, int)> _checked = {};
  bool _selecting = false;

  final ScrollController _scroll = ScrollController();

  /// The document revision the selection state belongs to. Any edit,
  /// undo, or redo can shift /Annots slots, so a new revision drops it.
  PdfDocument? _builtFor;

  /// The panel width while a resize drag is in flight, overriding the
  /// preference until the drag ends and persists it.
  double? _dragWidth;

  PdfEditingPreferences get _preferences => widget.controller.preferences;

  double get _width => (_dragWidth ??
          _preferences.annotationSidebarWidth ??
          widget.width)
      .clamp(widget.minWidth, widget.maxWidth);

  @override
  void initState() {
    super.initState();
    _preferences.addListener(_onPreferences);
  }

  @override
  void didUpdateWidget(PdfAnnotationSidebar old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller.preferences, _preferences)) {
      old.controller.preferences.removeListener(_onPreferences);
      _preferences.addListener(_onPreferences);
    }
  }

  @override
  void dispose() {
    _preferences.removeListener(_onPreferences);
    _scroll.dispose();
    super.dispose();
  }

  void _onPreferences() {
    if (mounted) setState(() {});
  }

  void _onResizeDelta(double delta) => setState(() {
        _dragWidth =
            (_width + delta).clamp(widget.minWidth, widget.maxWidth);
      });

  void _onResizeEnd() {
    if (_dragWidth == null) return;
    _preferences.annotationSidebarWidth = _dragWidth;
    setState(() => _dragWidth = null);
  }

  static IconData _icon(String subtype) => switch (subtype) {
        'Highlight' => Icons.border_color,
        'Underline' => Icons.format_underlined,
        'StrikeOut' => Icons.format_strikethrough,
        'Squiggly' => Icons.gesture,
        'Ink' => Icons.draw,
        'Square' => Icons.rectangle_outlined,
        'Circle' => Icons.circle_outlined,
        'FreeText' => Icons.text_fields,
        'Text' => Icons.sticky_note_2_outlined,
        'Stamp' => Icons.approval,
        'Link' => Icons.link,
        'Widget' => Icons.input,
        'FileAttachment' => Icons.attach_file,
        _ => Icons.bookmark_border,
      };

  static String _label(String subtype) => switch (subtype) {
        'StrikeOut' => 'Strike-out',
        'FreeText' => 'Text box',
        'Text' => 'Note',
        'Widget' => 'Form field',
        _ => subtype,
      };

  void _toggle((int, int) slot) => setState(() {
        if (!_checked.add(slot)) _checked.remove(slot);
      });

  Widget _tile(BuildContext context, int pageIndex, int index,
      PdfAnnotation annotation) {
    final slot = (pageIndex, index);
    final selectable = !_unselectable.contains(annotation.subtype);
    // on widgets /T is the field name, not an author
    final author = annotation.subtype == 'Widget' ? null : annotation.author;
    final contents = annotation.contents;
    final detail = [
      if (author != null && author.isNotEmpty) author,
      if (contents != null && contents.isNotEmpty) contents,
    ].join(' — ');
    return ListTile(
      dense: true,
      leading: _selecting
          ? Checkbox(
              value: _checked.contains(slot),
              onChanged: selectable ? (_) => _toggle(slot) : null,
            )
          : Icon(_icon(annotation.subtype), size: 20),
      title: Text(_label(annotation.subtype)),
      subtitle: detail.isEmpty
          ? null
          : Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
      // viewer multi-selection shows here too
      selected:
          !_selecting && widget.controller.isAnnotationSelected(pageIndex, index),
      onTap: _selecting
          ? (selectable ? () => _toggle(slot) : null)
          : () {
              unawaited(
                  widget.viewerController.showRect(pageIndex, annotation.rect));
              if (selectable) {
                widget.controller.selectAnnotation(pageIndex, index);
              }
              // pulse it on the page so the eye lands right
              widget.controller.flashAnnotation(pageIndex, index);
            },
      onLongPress: selectable && !_selecting
          ? () => setState(() {
                _selecting = true;
                _checked.add(slot);
              })
          : null,
      trailing: _selecting || !selectable
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Delete',
              onPressed: () =>
                  widget.controller.deleteAnnotation(pageIndex, index),
            ),
    );
  }

  Widget _selectionHeader(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          tooltip: 'Cancel selection',
          onPressed: () => setState(() {
            _selecting = false;
            _checked.clear();
          }),
        ),
        Text('${_checked.length} selected',
            style: Theme.of(context).textTheme.labelLarge),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 20),
          tooltip: 'Delete selected',
          onPressed: _checked.isEmpty
              ? null
              : () => widget.controller.deleteAnnotations(_checked.toList()),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _width,
      child: Stack(children: [
        Positioned.fill(
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final document = widget.controller.document;
                if (!identical(document, _builtFor)) {
                  // already rebuilding — adjust the state in place
                  _builtFor = document;
                  _checked.clear();
                  _selecting = false;
                }
                final children = <Widget>[];
                for (var page = 0; page < document.pageCount; page++) {
                  final annotations =
                      widget.controller.pageAt(page).annotations;
                  final tiles = <Widget>[];
                  for (var i = 0; i < annotations.length; i++) {
                    final annotation = annotations[i];
                    if (_unlisted.contains(annotation.subtype)) continue;
                    tiles.add(_tile(context, page, i, annotation));
                  }
                  if (tiles.isNotEmpty) {
                    children
                      ..add(Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('Page ${page + 1}',
                            style: Theme.of(context).textTheme.labelLarge),
                      ))
                      ..addAll(tiles);
                  }
                }
                // the viewer-style scrollbar replaces the implicit
                // desktop bar; it wraps only the list, so the
                // multi-select header above stays clear of it. Stepped
                // off the resize grip when the grip rides the same
                // (right) edge.
                final list = children.isEmpty
                    ? const Center(child: Text('No annotations'))
                    : Stack(children: [
                        ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child:
                              ListView(controller: _scroll, children: children),
                        ),
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: widget.resizable &&
                                  widget.side == PdfSidebarSide.left
                              ? PdfSidebarResizeGrip.width
                              : 0,
                          child: PdfScrollbar(
                            scroll: _scroll,
                            thumbKey: const ValueKey(
                                'pdf-annotation-scrollbar-thumb'),
                          ),
                        ),
                      ]);
                // one shape for both modes, with the list keyed: the
                // header appearing must not move the list to a new
                // element (the controller would sit attached to two
                // scroll views for a frame)
                return Column(children: [
                  if (_selecting) _selectionHeader(context),
                  Expanded(
                    key: const ValueKey('pdf-annotation-list'),
                    child: list,
                  ),
                ]);
              },
            ),
          ),
        ),
        if (widget.resizable)
          Positioned(
            top: 0,
            bottom: 0,
            left: widget.side == PdfSidebarSide.right ? 0 : null,
            right: widget.side == PdfSidebarSide.left ? 0 : null,
            child: PdfSidebarResizeGrip(
              key: const ValueKey('pdf-annotation-resize-grip'),
              side: widget.side,
              onWidthDelta: _onResizeDelta,
              onResizeEnd: _onResizeEnd,
            ),
          ),
      ]),
    );
  }
}
