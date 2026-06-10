import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:pdf_document/pdf_document.dart';

import 'renderer.dart';

/// Displays a single PDF page, rendered natively in Dart.
///
/// The page is interpreted once into a [ui.Picture]; changing [scale] only
/// re-rasterizes that cached picture, so zoom-driven re-renders are cheap.
/// Tiled rendering past the resolution caps is a TODO.
class PdfPageView extends StatefulWidget {
  const PdfPageView({super.key, required this.page, this.scale = 1});

  final PdfPage page;

  /// Resolution multiplier on top of the device pixel ratio. The viewer
  /// raises it to the settled zoom level so pages stay sharp.
  final double scale;

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  Future<ui.Picture>? _picture;
  ui.Image? _image;
  int _renderGeneration = 0;
  double? _pixelRatio;

  // Deep-zoom rasters stay within GPU texture limits and sane memory:
  // at most ~16.7M px (64 MB RGBA) and 8192 px per side. Past these caps
  // the bitmap is upscaled (blurry) — sharp deep zoom needs tiles.
  static const _maxPixels = 1 << 24;
  static const _maxDimension = 8192.0;

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
    if (!identical(oldWidget.page, widget.page)) {
      _dropPicture();
      _render();
    } else if (oldWidget.scale != widget.scale) {
      _render();
    }
  }

  @override
  void dispose() {
    _dropPicture();
    _image?.dispose();
    super.dispose();
  }

  void _dropPicture() {
    _picture?.then((picture) => picture.dispose());
    _picture = null;
  }

  double _effectiveRatio() {
    final size = PdfPageRenderer.pageSize(widget.page);
    final width = math.max(1.0, size.width);
    final height = math.max(1.0, size.height);
    var ratio = (_pixelRatio ?? 1.0) * widget.scale;
    ratio = math.min(ratio, math.sqrt(_maxPixels / (width * height)));
    ratio = math.min(ratio, _maxDimension / math.max(width, height));
    return math.max(ratio, 0.05);
  }

  Future<void> _render() async {
    final generation = ++_renderGeneration;
    final picture =
        await (_picture ??= PdfPageRenderer.renderPicture(widget.page));
    if (!mounted || generation != _renderGeneration) return;
    final image = await PdfPageRenderer.rasterize(
        picture, PdfPageRenderer.pageSize(widget.page), _effectiveRatio());
    if (!mounted || generation != _renderGeneration) {
      image.dispose();
      return;
    }
    // the previous raster stays up (transform-scaled) until this replaces
    // it, so zooming never flashes white
    setState(() {
      _image?.dispose();
      _image = image;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = PdfPageRenderer.pageSize(widget.page);
    final hasArea = size.width > 0 && size.height > 0;
    return AspectRatio(
      aspectRatio: hasArea ? size.width / size.height : 1,
      child: _image == null
          ? const ColoredBox(color: Color(0xFFFFFFFF))
          : RawImage(
              image: _image,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
    );
  }
}
