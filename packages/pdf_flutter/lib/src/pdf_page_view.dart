import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:pdf_document/pdf_document.dart';

import 'renderer.dart';

/// Displays a single PDF page, rendered natively in Dart.
///
/// Renders at the device pixel ratio. Tiled rendering for deep zoom and
/// render-ahead caching come with the viewer widget.
class PdfPageView extends StatefulWidget {
  const PdfPageView({super.key, required this.page});

  final PdfPage page;

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  ui.Image? _image;
  int _renderGeneration = 0;
  double? _pixelRatio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    if (ratio != _pixelRatio) {
      _pixelRatio = ratio;
      _render();
    }
  }

  @override
  void didUpdateWidget(PdfPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.page, widget.page)) _render();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _render() async {
    final generation = ++_renderGeneration;
    final image = await PdfPageRenderer.renderImage(widget.page,
        pixelRatio: _pixelRatio ?? 1.0);
    if (!mounted || generation != _renderGeneration) {
      image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
    });
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.page.cropBox;
    final rotated = widget.page.rotation == 90 || widget.page.rotation == 270;
    final width = rotated ? box.height : box.width;
    final height = rotated ? box.width : box.height;
    final hasArea = width > 0 && height > 0;
    return AspectRatio(
      aspectRatio: hasArea ? width / height : 1,
      child: _image == null
          ? const ColoredBox(color: Color(0xFFFFFFFF))
          : RawImage(image: _image, fit: BoxFit.contain),
    );
  }
}
