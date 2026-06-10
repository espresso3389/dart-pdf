import 'package:flutter/material.dart';

/// Signature of the prompt the editing UI uses to ask for annotation text
/// (free text, notes, stamps). Returns null when the user cancels.
typedef PdfTextPrompt = Future<String?> Function(
  BuildContext context, {
  required String title,
  String initial,
  bool multiline,
});

/// The default [PdfTextPrompt]: a one-field Material dialog.
Future<String?> showPdfTextPrompt(
  BuildContext context, {
  required String title,
  String initial = '',
  bool multiline = false,
}) {
  final field = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        maxLines: multiline ? 4 : 1,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(field.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
