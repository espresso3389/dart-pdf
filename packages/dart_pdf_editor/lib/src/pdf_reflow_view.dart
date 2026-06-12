import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

/// A text-first view of a PDF document.
///
/// The PDF page graphics are not rendered here. Instead the content stream is
/// interpreted for positioned text, then [PdfTextExtractor] infers visual
/// lines, reading order, and paragraph blocks. This is useful for narrow
/// screens and accessibility-style reading where fixed page layout is less
/// important than continuous text.
class PdfReflowView extends StatefulWidget {
  const PdfReflowView({
    super.key,
    required this.document,
    this.backgroundColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
    this.maxWidth = 760,
  });

  final PdfDocument document;
  final Color? backgroundColor;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  @override
  State<PdfReflowView> createState() => _PdfReflowViewState();
}

class _PdfReflowViewState extends State<PdfReflowView> {
  late Future<List<PdfReflowPage>> _pages;

  @override
  void initState() {
    super.initState();
    _pages = _loadPages();
  }

  @override
  void didUpdateWidget(PdfReflowView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.document, oldWidget.document)) {
      _pages = _loadPages();
    }
  }

  Future<List<PdfReflowPage>> _loadPages() async {
    // Give the first frame a chance to show progress before long documents walk
    // every content stream.
    await Future<void>.delayed(Duration.zero);
    return [
      for (var i = 0; i < widget.document.pageCount; i++)
        PdfTextExtractor.reflowPage(widget.document, i),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background =
        widget.backgroundColor ?? theme.colorScheme.surfaceContainerLowest;
    return ColoredBox(
      color: background,
      child: FutureBuilder<List<PdfReflowPage>>(
        future: _pages,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final pages = snapshot.data ?? const <PdfReflowPage>[];
          if (pages.every((page) => page.blocks.isEmpty)) {
            return Center(
              child: Text(
                'No extractable text',
                style: theme.textTheme.bodyLarge,
              ),
            );
          }
          return ListView.builder(
            key: const ValueKey('pdf-reflow-view'),
            padding: widget.padding,
            itemCount: pages.length,
            itemBuilder: (context, index) => Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.maxWidth),
                child: _ReflowPage(page: pages[index]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ReflowPage extends StatelessWidget {
  const _ReflowPage({required this.page});

  final PdfReflowPage page;

  @override
  Widget build(BuildContext context) {
    if (page.blocks.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final median = _median(page.blocks.map((block) => block.fontSize));
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Page ${page.pageIndex + 1}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final block in page.blocks)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(
                block.text,
                style: _styleFor(theme, block, median),
              ),
            ),
        ],
      ),
    );
  }

  TextStyle? _styleFor(
      ThemeData theme, PdfReflowBlock block, double pageMedian) {
    final base = block.fontSize >= pageMedian * 1.3
        ? theme.textTheme.titleMedium
        : theme.textTheme.bodyLarge;
    return base?.copyWith(
      height: 1.45,
      fontWeight: block.fontSize >= pageMedian * 1.3
          ? FontWeight.w600
          : base.fontWeight,
    );
  }
}

double _median(Iterable<double> values) {
  final sorted = [...values]..sort();
  if (sorted.isEmpty) return 0;
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) / 2;
}
