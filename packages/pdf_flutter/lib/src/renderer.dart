import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

import 'canvas_device.dart';
import 'image_decoder.dart';

/// Rasterizes PDF pages.
///
/// Two passes: first an [ImageCollector] walk finds image XObjects so they
/// can be decoded asynchronously, then the page is painted synchronously
/// onto a recorded canvas.
class PdfPageRenderer {
  PdfPageRenderer._();

  /// Renders [page] into a picture at 1 unit = 1 PDF point, cropped to the
  /// page's crop box and rotated per /Rotate.
  static Future<ui.Picture> renderPicture(PdfPage page) async {
    final cos = page.document.cos;

    final collector = ImageCollector();
    PdfInterpreter(cos: cos, device: collector)
      ..drawPage(page)
      ..drawAnnotations(page);
    final images = await decodeImages(cos, collector.streams);

    final box = page.cropBox;
    final size = pageSize(page);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    switch (page.rotation) {
      case 90:
        canvas.translate(size.width, 0);
        canvas.rotate(math.pi / 2);
      case 180:
        canvas.translate(size.width, size.height);
        canvas.rotate(math.pi);
      case 270:
        canvas.translate(0, size.height);
        canvas.rotate(-math.pi / 2);
    }
    // PDF user space is y-up with the crop box's own origin
    canvas.translate(0, box.height);
    canvas.scale(1, -1);
    canvas.translate(-box.left, -box.bottom);

    PdfInterpreter(cos: cos, device: CanvasPdfDevice(canvas, images: images))
      ..drawPage(page)
      ..drawAnnotations(page);
    return recorder.endRecording();
  }

  /// Renders [page] to a bitmap. [pixelRatio] of 2 doubles the resolution.
  static Future<ui.Image> renderImage(PdfPage page,
      {double pixelRatio = 1}) async {
    final picture = await renderPicture(page);
    try {
      return await rasterize(picture, pageSize(page), pixelRatio);
    } finally {
      picture.dispose();
    }
  }

  /// Rasterizes an already-recorded page [picture] (sized [size] points) —
  /// re-rasterizing a cached picture at a new zoom skips re-interpreting
  /// the page entirely.
  static Future<ui.Image> rasterize(
      ui.Picture picture, Size size, double pixelRatio) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(pixelRatio)
      ..drawPicture(picture);
    final scaled = recorder.endRecording();
    try {
      return await scaled.toImage(
        (size.width * pixelRatio).ceil().clamp(1, 1 << 14),
        (size.height * pixelRatio).ceil().clamp(1, 1 << 14),
      );
    } finally {
      scaled.dispose();
    }
  }

  /// Rasterizes only [region] (in page points, y-down raster space) of a
  /// recorded page [picture] at [pixelRatio] — the deep-zoom detail patch.
  static Future<ui.Image> rasterizeRegion(
      ui.Picture picture, Rect region, double pixelRatio) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(pixelRatio)
      ..translate(-region.left, -region.top)
      ..drawPicture(picture);
    final scaled = recorder.endRecording();
    try {
      return await scaled.toImage(
        (region.width * pixelRatio).ceil().clamp(1, 1 << 14),
        (region.height * pixelRatio).ceil().clamp(1, 1 << 14),
      );
    } finally {
      scaled.dispose();
    }
  }

  /// Samples the rendered color of [page] at [point] — page raster space,
  /// i.e. post-rotation points with y down (view coordinates divided by
  /// the view scale). Averages a 3×3-point patch so anti-aliased strokes
  /// still read as their color. Returns null off the page.
  static Future<ui.Color?> sampleColor(PdfPage page, ui.Offset point) async {
    final picture = await renderPicture(page);
    try {
      final image = await rasterizeRegion(
          picture, Rect.fromCenter(center: point, width: 3, height: 3), 1);
      try {
        final data = await image.toByteData();
        if (data == null) return null;
        var r = 0, g = 0, b = 0, n = 0;
        for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
          if (data.getUint8(i + 3) == 0) continue; // past the page edge
          r += data.getUint8(i);
          g += data.getUint8(i + 1);
          b += data.getUint8(i + 2);
          n++;
        }
        return n == 0 ? null : ui.Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  /// Page size in points after applying /Rotate.
  static Size pageSize(PdfPage page) {
    final box = page.cropBox;
    final swap = page.rotation == 90 || page.rotation == 270;
    return swap ? Size(box.height, box.width) : Size(box.width, box.height);
  }
}
