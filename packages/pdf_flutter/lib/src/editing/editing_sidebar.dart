import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import '../pdf_viewer.dart';
import 'editing_controller.dart';

/// A panel listing every annotation in the document, grouped by page,
/// each tile showing its author (/T) when the annotation carries one.
///
/// Tapping a tile zooms the viewer to the annotation and selects it
/// (arming the select tool); the trailing button deletes it. A long
/// press starts multi-select: checkboxes replace the icons, tapping
/// toggles, and the header's delete removes everything checked as one
/// undo step. The list rebuilds on every revision, so it always
/// reflects the current state — including undo and redo.
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
  });

  final PdfEditingController controller;

  /// The viewer to navigate when a tile is tapped.
  final PdfViewerController viewerController;

  final double width;

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

  /// The document revision the selection state belongs to. Any edit,
  /// undo, or redo can shift /Annots slots, so a new revision drops it.
  PdfDocument? _builtFor;

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
      PdfAnnotation annotation, (int, int)? selected) {
    final slot = (pageIndex, index);
    final selectable = !_unselectable.contains(annotation.subtype);
    // on widgets /T is the field name, not an author
    final author =
        annotation.subtype == 'Widget' ? null : annotation.author;
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
      selected: !_selecting && selected == slot,
      onTap: _selecting
          ? (selectable ? () => _toggle(slot) : null)
          : () {
              unawaited(
                  widget.viewerController.showRect(pageIndex, annotation.rect));
              if (selectable) {
                widget.controller.selectAnnotation(pageIndex, index);
              }
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
      width: widget.width,
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
            final selected = widget.controller.selectedAnnotationSlot;
            final children = <Widget>[];
            for (var page = 0; page < document.pageCount; page++) {
              final annotations = document.page(page).annotations;
              final tiles = <Widget>[];
              for (var i = 0; i < annotations.length; i++) {
                final annotation = annotations[i];
                if (_unlisted.contains(annotation.subtype)) continue;
                tiles.add(_tile(context, page, i, annotation, selected));
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
            final list = children.isEmpty
                ? const Center(child: Text('No annotations'))
                : ListView(children: children);
            if (!_selecting) return list;
            return Column(children: [
              _selectionHeader(context),
              Expanded(child: list),
            ]);
          },
        ),
      ),
    );
  }
}
