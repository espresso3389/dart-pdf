import 'dart:async';

import 'package:flutter/material.dart';

import '../pdf_viewer.dart';
import 'editing_controller.dart';

/// A panel listing every annotation in the document, grouped by page.
///
/// Tapping a tile jumps the viewer to its page and selects it (arming
/// the select tool); the trailing button deletes it. The list rebuilds on
/// every revision, so it always reflects the current state — including
/// undo and redo.
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
class PdfAnnotationSidebar extends StatelessWidget {
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

  /// Links and form fields are listed but not selectable (the select
  /// tool refuses them too); popups belong to their parent annotation
  /// and are not listed at all.
  static const _unlisted = {'Popup'};
  static const _unselectable = {'Link', 'Widget'};

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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final document = controller.document;
            final selected = controller.selectedAnnotationSlot;
            final children = <Widget>[];
            for (var page = 0; page < document.pageCount; page++) {
              final annotations = document.page(page).annotations;
              final tiles = <Widget>[];
              for (var i = 0; i < annotations.length; i++) {
                final annotation = annotations[i];
                if (_unlisted.contains(annotation.subtype)) continue;
                final selectable =
                    !_unselectable.contains(annotation.subtype);
                final contents = annotation.contents;
                final pageIndex = page, index = i;
                tiles.add(ListTile(
                  dense: true,
                  leading: Icon(_icon(annotation.subtype), size: 20),
                  title: Text(_label(annotation.subtype)),
                  subtitle: contents == null || contents.isEmpty
                      ? null
                      : Text(contents,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                  selected: selected == (pageIndex, index),
                  onTap: () {
                    unawaited(viewerController.jumpToPage(pageIndex));
                    if (selectable) {
                      controller.selectAnnotation(pageIndex, index);
                    }
                  },
                  trailing: selectable
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: 'Delete',
                          onPressed: () =>
                              controller.deleteAnnotation(pageIndex, index),
                        )
                      : null,
                ));
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
            if (children.isEmpty) {
              return const Center(child: Text('No annotations'));
            }
            return ListView(children: children);
          },
        ),
      ),
    );
  }
}
