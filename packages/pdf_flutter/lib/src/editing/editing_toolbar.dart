import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart' show PdfStandardFont;

import '../pdf_viewer.dart';
import 'editing_color_picker.dart';
import 'editing_controller.dart';
import 'editing_signature.dart';
import 'editing_stamps.dart';
import 'text_prompt.dart';

/// A ready-made Material toolbar for [PdfEditingController]: text-markup
/// actions for the viewer's current selection, tool toggles, a color
/// palette, undo/redo, selection actions, flatten, and save.
///
/// Place it in a Scaffold's `bottomNavigationBar` (it builds a
/// [BottomAppBar]). Apps wanting different chrome can skip this widget
/// entirely and drive the controller from their own UI.
class PdfEditingToolbar extends StatelessWidget {
  const PdfEditingToolbar({
    super.key,
    required this.controller,
    required this.viewerController,
    this.onSave,
    this.textPrompt = showPdfTextPrompt,
    this.palette = defaultPalette,
  });

  final PdfEditingController controller;

  /// The viewer the markup buttons read the text selection from.
  final PdfViewerController viewerController;

  /// Receives the current revision's bytes when the save button is
  /// pressed; the button is hidden when null. Writing the bytes somewhere
  /// is the app's job.
  final void Function(Uint8List bytes)? onSave;

  /// How the edit-text button asks for replacement text.
  final PdfTextPrompt textPrompt;

  /// The colors offered for new annotations.
  final List<Color> palette;

  static const defaultPalette = [
    Color(0xFFE53935), // red
    Color(0xFFFFD100), // marker yellow
    Color(0xFF43A047), // green
    Color(0xFF1E88E5), // blue
    Color(0xFF000000), // black
  ];

  void _markup(PdfMarkupKind kind) {
    // capture before the edit: the document swap clears the selection
    final quadsByPage = {
      for (final page in viewerController.selectionPages)
        page: viewerController.selectionRectsOn(page),
    };
    controller.addMarkup(kind, quadsByPage);
  }

  void _toggleTool(PdfEditTool value) {
    controller.tool = controller.tool == value ? null : value;
    if (controller.tool != null) viewerController.clearSelection();
  }

  /// Arms the signature tool, collecting a signature first when none is
  /// saved yet. Tapping again while armed disarms, like any tool.
  Future<void> _toggleSignatureTool(BuildContext context) async {
    if (controller.tool == PdfEditTool.signature) {
      controller.tool = null;
      return;
    }
    if (controller.signature == null && !await _drawSignature(context)) {
      return;
    }
    _toggleTool(PdfEditTool.signature);
  }

  Future<bool> _drawSignature(BuildContext context) async {
    final signature = await showPdfSignatureDialog(context);
    if (signature == null) return false;
    controller.signature = signature;
    return true;
  }

  Future<void> _editElementText(BuildContext context) async {
    final element = controller.selectedElement;
    if (element == null) return;
    final text = await textPrompt(
      context,
      title: 'Replace text',
      initial: element.text ?? '',
      multiline: false,
    );
    if (text == null || text.isEmpty || text == element.text) return;
    controller.replaceSelectedElementText(text);
  }

  Future<void> _editSelectedText(BuildContext context) async {
    final annotation = controller.selectedAnnotation;
    if (annotation == null) return;
    final text = await textPrompt(
      context,
      title: switch (annotation.subtype) {
        'FreeText' => 'Text',
        'Stamp' => 'Stamp text',
        _ => 'Note',
      },
      initial: controller.selectedText ?? '',
      multiline: annotation.subtype != 'Stamp',
    );
    if (text == null || text.isEmpty) return;
    controller.setSelectedText(text);
  }

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListenableBuilder(
        listenable: Listenable.merge([controller, viewerController]),
        builder: (context, _) {
          final hasTextSelection = viewerController.hasSelection;
          final selected = controller.selectedAnnotation;

          Widget toolButton(PdfEditTool value, IconData icon, String tip) =>
              IconButton(
                icon: Icon(icon),
                tooltip: tip,
                isSelected: controller.tool == value,
                onPressed: () => _toggleTool(value),
              );

          Widget markupButton(PdfMarkupKind kind, IconData icon, String tip) =>
              IconButton(
                icon: Icon(icon),
                tooltip: tip,
                onPressed: hasTextSelection ? () => _markup(kind) : null,
              );

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Undo (⌘Z)',
                onPressed: controller.canUndo ? controller.undo : null,
              ),
              IconButton(
                icon: const Icon(Icons.redo),
                tooltip: 'Redo (⇧⌘Z)',
                onPressed: controller.canRedo ? controller.redo : null,
              ),
              const VerticalDivider(width: 16),
              markupButton(PdfMarkupKind.highlight, Icons.border_color,
                  'Highlight selection'),
              markupButton(PdfMarkupKind.underline, Icons.format_underlined,
                  'Underline selection'),
              markupButton(PdfMarkupKind.strikeOut, Icons.format_strikethrough,
                  'Strike out selection'),
              markupButton(PdfMarkupKind.squiggly, Icons.gesture,
                  'Squiggly-underline selection'),
              const VerticalDivider(width: 16),
              toolButton(PdfEditTool.select, Icons.near_me, 'Select'),
              if (selected != null) ...[
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: switch (controller.selectedAnnotationSlots.length) {
                    1 => 'Delete annotation',
                    final n => 'Delete $n annotations',
                  },
                  onPressed: controller.deleteSelected,
                ),
                if (controller.canEditSelectedText)
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Edit annotation text',
                    onPressed: () => _editSelectedText(context),
                  ),
              ],
              toolButton(PdfEditTool.ink, Icons.draw, 'Draw'),
              if (controller.tool == PdfEditTool.ink)
                IconButton(
                  icon: const Icon(Icons.touch_app),
                  tooltip: controller.fingerDrawsInk
                      ? 'Finger draws — tap so it scrolls instead'
                      : 'Finger scrolls (pen draws) — tap so it draws',
                  isSelected: controller.fingerDrawsInk,
                  onPressed: () =>
                      controller.fingerDrawsInk = !controller.fingerDrawsInk,
                ),
              // with auto-commit (the default) strokes land on their own
              // and undo covers regret — confirm buttons are manual-mode
              if (controller.hasPendingInk && !controller.inkAutoCommits) ...[
                IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Add ink annotation',
                  onPressed: controller.finishInk,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Discard drawing',
                  onPressed: controller.discardInk,
                ),
              ],
              toolButton(
                  PdfEditTool.rectangle, Icons.rectangle_outlined, 'Rectangle'),
              toolButton(PdfEditTool.ellipse, Icons.circle_outlined, 'Ellipse'),
              toolButton(PdfEditTool.freeText, Icons.text_fields, 'Text box'),
              toolButton(
                  PdfEditTool.note, Icons.sticky_note_2_outlined, 'Note'),
              toolButton(PdfEditTool.stamp, Icons.approval, 'Stamp'),
              if (controller.tool == PdfEditTool.stamp)
                IconButton(
                  icon: const Icon(Icons.style),
                  tooltip: 'Custom stamps…',
                  isSelected: controller.activeStamp != null,
                  onPressed: () =>
                      showPdfStampPicker(context, controller: controller),
                ),
              IconButton(
                icon: const Icon(Icons.history_edu),
                tooltip: 'Signature — tap a page to place it',
                isSelected: controller.tool == PdfEditTool.signature,
                onPressed: () => _toggleSignatureTool(context),
              ),
              if (controller.tool == PdfEditTool.signature)
                IconButton(
                  icon: const Icon(Icons.restart_alt),
                  tooltip: 'Draw a new signature…',
                  onPressed: () => _drawSignature(context),
                ),
              toolButton(PdfEditTool.content, Icons.format_shapes,
                  'Edit page content'),
              if (controller.selectedElement != null) ...[
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete element',
                  onPressed: controller.deleteSelectedElement,
                ),
                if (controller.canEditSelectedElementText)
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Replace text',
                    onPressed: () => _editElementText(context),
                  ),
              ],
              const VerticalDivider(width: 16),
              for (final color in palette)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: InkWell(
                    onTap: () => controller.color = color,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          // theme outline: visible on light and dark chrome
                          color: controller.color == color
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                          width: controller.color == color ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
              IconButton(
                icon: Icon(Icons.palette, color: controller.color),
                tooltip: 'More colors…',
                onPressed: () async {
                  final picked = await showPdfColorPicker(context,
                      initial: controller.color,
                      initialFormat:
                          controller.preferences.colorPickerFormat,
                      onFormatChanged: (format) =>
                          controller.preferences.colorPickerFormat = format);
                  if (picked != null) controller.color = picked;
                },
              ),
              IconButton(
                icon: const Icon(Icons.colorize),
                tooltip: 'Pick a color from the page',
                isSelected: controller.isPickingColor,
                onPressed: () => controller.isPickingColor
                    ? controller.cancelColorPick()
                    : controller.startColorPick(),
              ),
              _StyleMenu(controller: controller, palette: palette),
              const VerticalDivider(width: 16),
              IconButton(
                icon: const Icon(Icons.layers),
                tooltip: 'Flatten annotations into the pages',
                onPressed: controller.flattenAllAnnotations,
              ),
              if (onSave != null)
                IconButton(
                  icon: const Icon(Icons.save_alt),
                  tooltip: 'Save…',
                  onPressed: () => onSave!(controller.bytes),
                ),
            ]),
          );
        },
      ),
    );
  }
}

/// The style popup: sliders for stroke width, opacity, and font size,
/// the font family for free text, and the text box's fill and border
/// colors. With a free-text annotation selected, the text controls show
/// — and change — that annotation's style; otherwise they set the style
/// new text is created with.
class _StyleMenu extends StatefulWidget {
  const _StyleMenu({required this.controller, required this.palette});

  final PdfEditingController controller;

  /// The colors offered as fill/border swatches (the toolbar's palette).
  final List<Color> palette;

  @override
  State<_StyleMenu> createState() => _StyleMenuState();
}

class _StyleMenuState extends State<_StyleMenu> {
  PdfEditingController get controller => widget.controller;

  /// The font-size slider's in-flight value while dragging over a
  /// selected annotation — the annotation only restyles on release (one
  /// revision per gesture), so the thumb needs its own state meanwhile.
  double? _draggingFontSize;

  void _setFontFamily(PdfStandardFont font) {
    controller.fontFamily = font; // the new default either way
    if (controller.canRestyleSelectedText) {
      controller.restyleSelectedText(font: font);
    }
  }

  static int? _rgb(Color? color) =>
      color == null ? null : color.toARGB32() & 0xFFFFFF;

  void _setTextFill(Color? color) {
    controller.textFillColor = color; // the new default either way
    if (controller.canRestyleSelectedText) {
      controller.restyleSelectedText(fill: (_rgb(color),));
    }
  }

  void _setTextBorder(Color? color) {
    controller.textBorderColor = color;
    if (controller.canRestyleSelectedText) {
      controller.restyleSelectedText(
          border: (_rgb(color),),
          // setting a border gives it the current stroke width; clearing
          // one leaves the width field alone
          borderWidth: color == null ? null : controller.strokeWidth);
    }
  }

  /// One text-box color row: a "none" swatch, the palette, and a custom
  /// picker. [onChanged] receives the chosen color, or null for none.
  Widget _boxColorRow({
    required BuildContext context,
    required String label,
    required String keyPrefix,
    required Color? value,
    required ValueChanged<Color?> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Widget swatch(
            {required Key key,
            required Color? color,
            required bool selected,
            required VoidCallback onTap}) =>
        Padding(
          // 1px keeps six swatches + the picker inside the menu's 268px
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: InkWell(
            key: key,
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: color ?? const Color(0xFFFFFFFF),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outline,
                  width: selected ? 3 : 1,
                ),
              ),
              child: color == null
                  ? const CustomPaint(painter: _NoneSlashPainter())
                  : null,
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        SizedBox(width: 86, child: Text(label)),
        swatch(
          key: ValueKey('$keyPrefix-none'),
          color: null,
          selected: value == null,
          onTap: () => onChanged(null),
        ),
        for (var i = 0; i < widget.palette.length; i++)
          swatch(
            key: ValueKey('$keyPrefix-$i'),
            color: widget.palette[i],
            selected: value != null &&
                (value.toARGB32() & 0xFFFFFF) ==
                    (widget.palette[i].toARGB32() & 0xFFFFFF),
            onTap: () => onChanged(widget.palette[i]),
          ),
        IconButton(
          icon: const Icon(Icons.palette_outlined, size: 18),
          tooltip: 'More colors…',
          visualDensity: VisualDensity.compact,
          onPressed: () async {
            final picked = await showPdfColorPicker(context,
                initial: value ?? const Color(0xFFFFFFFF));
            if (picked != null) onChanged(picked);
          },
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        // the menu lives in its own overlay, outside the toolbar's
        // ListenableBuilder — it needs its own listener to track sliders
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final selectedStyle = controller.selectedTextStyle;
            // with a free text selected the rows show its own box style;
            // otherwise the creation defaults
            final restyling = controller.canRestyleSelectedText;
            final boxStyle =
                restyling ? controller.selectedAnnotation?.freeTextStyle : null;
            final fillValue = restyling
                ? (boxStyle?.fillColor != null
                    ? Color(0xFF000000 | boxStyle!.fillColor!)
                    : null)
                : controller.textFillColor;
            final borderValue = restyling
                ? (boxStyle?.borderColor != null && (boxStyle?.borderWidth ?? 0) > 0
                    ? Color(0xFF000000 | boxStyle!.borderColor!)
                    : null)
                : controller.textBorderColor;
            return Container(
              width: 300,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _slider(
                    label: 'Stroke width',
                    value: controller.strokeWidth,
                    min: 0.5,
                    max: 12,
                    display: '${controller.strokeWidth.toStringAsFixed(1)} pt',
                    onChanged: (v) => controller.strokeWidth = v,
                  ),
                  _slider(
                    label: 'Opacity',
                    value: controller.opacity,
                    min: 0.1,
                    max: 1,
                    display: '${(controller.opacity * 100).round()}%',
                    onChanged: (v) => controller.opacity = v,
                  ),
                  _slider(
                    label: 'Font size',
                    value: _draggingFontSize ??
                        selectedStyle?.size ??
                        controller.fontSize,
                    min: 8,
                    max: 48,
                    display:
                        '${(_draggingFontSize ?? selectedStyle?.size ?? controller.fontSize).round()} pt',
                    onChanged: (v) {
                      setState(() => _draggingFontSize = v.roundToDouble());
                      if (selectedStyle == null) {
                        controller.fontSize = v.roundToDouble();
                      }
                    },
                    onChangeEnd: (v) {
                      final size = v.roundToDouble();
                      controller.fontSize = size;
                      if (controller.canRestyleSelectedText) {
                        controller.restyleSelectedText(size: size);
                      }
                      setState(() => _draggingFontSize = null);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      const SizedBox(width: 86, child: Text('Font')),
                      Expanded(
                        child: SegmentedButton<PdfStandardFont>(
                          segments: const [
                            ButtonSegment(
                                value: PdfStandardFont.helvetica,
                                label: Text('Sans')),
                            ButtonSegment(
                                value: PdfStandardFont.times,
                                label: Text('Serif')),
                            ButtonSegment(
                                value: PdfStandardFont.courier,
                                label: Text('Mono')),
                          ],
                          selected: {
                            selectedStyle?.font ?? controller.fontFamily
                          },
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 8)),
                          ),
                          onSelectionChanged: (selection) =>
                              _setFontFamily(selection.single),
                        ),
                      ),
                    ]),
                  ),
                  _boxColorRow(
                    context: context,
                    label: 'Text fill',
                    keyPrefix: 'pdf-text-fill',
                    value: fillValue,
                    onChanged: _setTextFill,
                  ),
                  _boxColorRow(
                    context: context,
                    label: 'Text border',
                    keyPrefix: 'pdf-text-border',
                    value: borderValue,
                    onChanged: _setTextBorder,
                  ),
                ],
              ),
            );
          },
        ),
      ],
      builder: (context, menu, _) => IconButton(
        icon: const Icon(Icons.tune),
        tooltip: 'Stroke, opacity, font',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
  }) {
    return Row(children: [
      SizedBox(width: 86, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
      SizedBox(width: 44, child: Text(display, textAlign: TextAlign.end)),
    ]);
  }
}

/// The "no color" swatch's red diagonal slash.
class _NoneSlashPainter extends CustomPainter {
  const _NoneSlashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
        Offset(3, size.height - 3),
        Offset(size.width - 3, 3),
        Paint()
          ..color = const Color(0xFFE53935)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_NoneSlashPainter oldDelegate) => false;
}
