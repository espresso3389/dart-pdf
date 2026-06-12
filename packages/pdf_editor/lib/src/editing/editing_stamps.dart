import 'dart:convert';

import 'package:flutter/material.dart';

import 'editing_controller.dart';

/// A reusable rubber stamp the user authored: a caption and a color.
///
/// Custom stamps are saved on the local device through
/// [PdfEditingPreferences.customStamps], so they survive app restarts and
/// are shared across documents. The stamp tool places the
/// [PdfEditingController.activeStamp] with a tap; with none active it
/// falls back to the classic flow (drag a box, type the caption).
///
/// Serializes to JSON so [PdfEditingPreferences] can persist it.
class PdfCustomStamp {
  const PdfCustomStamp({required this.text, required this.color});

  /// The caption drawn inside the stamp's rounded border.
  final String text;

  /// RGB border and caption color.
  final int color;

  String encode() => jsonEncode({'text': text, 'color': color});

  /// Parses [encode]'s output; null for anything malformed.
  static PdfCustomStamp? decode(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return PdfCustomStamp(
        text: map['text'] as String,
        color: map['color'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PdfCustomStamp && other.text == text && other.color == color;

  @override
  int get hashCode => Object.hash(text, color);
}

/// Shows the stamp picker: choose the stamp the stamp tool places,
/// create a new one, or delete saved ones. Selections apply directly to
/// [controller].
Future<void> showPdfStampPicker(BuildContext context,
        {required PdfEditingController controller}) =>
    showDialog<void>(
      context: context,
      builder: (context) => PdfStampPickerDialog(controller: controller),
    );

/// The stamp picker dialog behind [showPdfStampPicker].
class PdfStampPickerDialog extends StatelessWidget {
  const PdfStampPickerDialog({super.key, required this.controller});

  final PdfEditingController controller;

  Future<void> _create(BuildContext context) async {
    final created = await showPdfStampEditor(context);
    if (created == null) return;
    controller.saveCustomStamp(created);
    controller.activeStamp = created;
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Stamps'),
      content: SizedBox(
        width: 340,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.keyboard_alt_outlined),
                  title: const Text('Type the text for each stamp'),
                  selected: controller.activeStamp == null,
                  onTap: () {
                    controller.activeStamp = null;
                    Navigator.of(context).pop();
                  },
                ),
                for (final stamp in controller.customStamps)
                  ListTile(
                    title: Align(
                      alignment: Alignment.centerLeft,
                      child: PdfStampPreview(stamp: stamp),
                    ),
                    selected: stamp == controller.activeStamp,
                    onTap: () {
                      controller.activeStamp = stamp;
                      Navigator.of(context).pop();
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete stamp',
                      onPressed: () => controller.removeCustomStamp(stamp),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _create(context),
          child: const Text('New stamp…'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Shows the stamp creation dialog; resolves to the new stamp, or null
/// on cancel. Saving it is the caller's job (the picker saves through
/// the controller).
Future<PdfCustomStamp?> showPdfStampEditor(BuildContext context) =>
    showDialog<PdfCustomStamp>(
      context: context,
      builder: (context) => const PdfStampEditorDialog(),
    );

/// The stamp creation dialog behind [showPdfStampEditor]: caption field,
/// color choice, and a live preview matching the placed appearance.
class PdfStampEditorDialog extends StatefulWidget {
  const PdfStampEditorDialog({super.key});

  @override
  State<PdfStampEditorDialog> createState() => _PdfStampEditorDialogState();
}

class _PdfStampEditorDialogState extends State<PdfStampEditorDialog> {
  static const _inks = [0xC03030, 0x2E7D32, 0x1A3E8C, 0xEF6C00, 0x000000];

  final _text = TextEditingController(text: 'APPROVED');
  int _color = _inks.first;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _caption => _text.text.trim();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New stamp'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: PdfStampPreview(
              stamp: PdfCustomStamp(
                text: _caption.isEmpty ? '…' : _caption,
                color: _color,
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 300,
            child: TextField(
              key: const ValueKey('pdf-stamp-text'),
              controller: _text,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Stamp text'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            for (final ink in _inks)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => setState(() => _color = ink),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Color(0xFF000000 | ink),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == ink
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                        width: _color == ink ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _caption.isEmpty
              ? null
              : () => Navigator.of(context)
                  .pop(PdfCustomStamp(text: _caption, color: _color)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Renders a stamp the way it will look on the page: bold caption inside
/// a rounded border, both in the stamp's color.
class PdfStampPreview extends StatelessWidget {
  const PdfStampPreview({super.key, required this.stamp});

  final PdfCustomStamp stamp;

  @override
  Widget build(BuildContext context) {
    final color = Color(0xFF000000 | stamp.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        stamp.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
