import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pdf_viewer.dart';

/// The classic "page 3 / 12" indicator, with the page number editable:
/// type a number and press enter to jump there.
///
/// Follows the viewer while it scrolls; out-of-range numbers clamp to
/// the document, junk input snaps back. Renders nothing while the
/// controller has no document.
class PdfPageNumberField extends StatefulWidget {
  const PdfPageNumberField({super.key, required this.controller, this.style});

  final PdfViewerController controller;

  /// Applied to both the field and the " / 12" suffix; defaults to the
  /// ambient [TextTheme.titleMedium].
  final TextStyle? style;

  @override
  State<PdfPageNumberField> createState() => _PdfPageNumberFieldState();
}

class _PdfPageNumberFieldState extends State<PdfPageNumberField> {
  final TextEditingController _field = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onViewer);
    _focus.addListener(_onFocus);
    _reset();
  }

  @override
  void didUpdateWidget(PdfPageNumberField old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onViewer);
      widget.controller.addListener(_onViewer);
      _reset();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onViewer);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onViewer() {
    // while the user is typing the field is theirs; it re-syncs on blur
    if (!_focus.hasFocus) _reset();
    if (mounted) setState(() {});
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      _field.selection =
          TextSelection(baseOffset: 0, extentOffset: _field.text.length);
    } else {
      _reset();
    }
  }

  void _reset() => _field.text = '${widget.controller.currentPage + 1}';

  void _submit(String value) {
    final count = widget.controller.pageCount;
    final page = int.tryParse(value.trim());
    if (page != null && count > 0) {
      final target = page.clamp(1, count) - 1;
      _field.text = '${target + 1}';
      unawaited(widget.controller.jumpToPage(target));
    } else {
      _reset();
    }
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.controller.pageCount;
    if (count == 0) return const SizedBox.shrink();
    final style = widget.style ?? Theme.of(context).textTheme.titleMedium;
    final digits = count.toString().length;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 24.0 + 10.0 * digits,
        child: TextField(
          key: const ValueKey('pdf-page-number-field'),
          controller: _field,
          focusNode: _focus,
          style: style,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            border: OutlineInputBorder(),
          ),
          onSubmitted: _submit,
        ),
      ),
      Text(' / $count', style: style),
    ]);
  }
}
