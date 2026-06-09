import 'package:flutter/widgets.dart';
import 'package:pdf_document/pdf_document.dart';

/// Displays a single PDF page.
///
/// Placeholder: reserves the page's aspect ratio and paints a blank sheet.
/// Will be backed by the content-stream interpreter in pdf_graphics once it
/// exists — the interpreter emits a display list in a background isolate,
/// and this widget replays it onto a Canvas.
class PdfPageView extends StatelessWidget {
  const PdfPageView({super.key, required this.page});

  final PdfPage page;

  @override
  Widget build(BuildContext context) {
    final box = page.cropBox;
    final hasArea = box.width > 0 && box.height > 0;
    return AspectRatio(
      aspectRatio: hasArea ? box.width / box.height : 1,
      child: const ColoredBox(color: Color(0xFFFFFFFF)),
    );
  }
}
