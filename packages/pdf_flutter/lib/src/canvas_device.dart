import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

/// Paints interpreter callbacks onto a Flutter [Canvas].
///
/// Expects the canvas to be set up in page space (PDF user space, y-up); the
/// renderer applies the global y-flip. Text is drawn with substituted system
/// fonts, horizontally scaled to the PDF's own metrics, until the font
/// engine produces real glyph outlines. Images must be pre-decoded into
/// [images] (painting is synchronous).
class CanvasPdfDevice implements PdfDevice {
  CanvasPdfDevice(this.canvas, {this.images = const {}});

  final Canvas canvas;
  final Map<CosStream, ui.Image> images;

  @override
  void save() => canvas.save();

  @override
  void restore() => canvas.restore();

  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha) {
    canvas.drawPath(
      _toUiPath(path, rule),
      Paint()
        ..style = PaintingStyle.fill
        ..color = _toColor(color, alpha),
    );
  }

  @override
  void strokePath(
      PdfPath path, PdfColor color, PdfStroke stroke, double alpha) {
    // TODO: dash patterns need a path-measuring dasher; drawn solid for now
    canvas.drawPath(
      _toUiPath(path, PdfFillRule.nonzero),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = _toColor(color, alpha)
        ..strokeWidth = stroke.width
        ..strokeCap = switch (stroke.cap) {
          1 => StrokeCap.round,
          2 => StrokeCap.square,
          _ => StrokeCap.butt,
        }
        ..strokeJoin = switch (stroke.join) {
          1 => StrokeJoin.round,
          2 => StrokeJoin.bevel,
          _ => StrokeJoin.miter,
        }
        ..strokeMiterLimit = stroke.miterLimit,
    );
  }

  @override
  void clipPath(PdfPath path, PdfFillRule rule) {
    canvas.clipPath(_toUiPath(path, rule));
  }

  @override
  void drawText(PdfTextRun run) {
    // Draw at 100px and scale down 100x: TextPainter quality degrades at
    // tiny sizes, and the run transform already encodes the real size.
    const renderSize = 100.0;
    final painter = TextPainter(
      text: TextSpan(text: run.text, style: _styleFor(run)),
      textDirection: TextDirection.ltr,
    )..layout();
    final baseline =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);

    canvas.save();
    canvas.transform(_toFloat64(run.transform));
    // unflip: the page transform is y-up, text rasterizes y-down
    final targetWidth = run.width * renderSize;
    final scaleX = run.width > 0 && painter.width > 0
        ? targetWidth / painter.width
        : 1.0;
    canvas.scale(scaleX / renderSize, -1 / renderSize);
    painter.paint(canvas, Offset(0, -baseline));
    canvas.restore();
  }

  @override
  void drawImage(PdfImageRequest request) {
    final image = images[request.stream];
    if (image == null) return; // not decodable (yet): skip silently
    canvas.save();
    canvas.transform(_toFloat64(request.transform));
    // image space: unit square, y-up; image pixels: y-down from the top
    canvas.translate(0, 1);
    canvas.scale(1, -1);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.from(
            alpha: request.alpha, red: 0, green: 0, blue: 0),
    );
    canvas.restore();
  }

  TextStyle _styleFor(PdfTextRun run) {
    final name = run.fontName ?? '';
    return TextStyle(
      color: _toColor(run.color, 1),
      fontSize: 100,
      fontFamily: switch (name) {
        _ when name.contains('Courier') || name.contains('Mono') =>
          'Courier',
        _ when name.contains('Times') || name.contains('Serif') =>
          'Times New Roman',
        _ => 'Helvetica',
      },
      fontWeight:
          name.contains('Bold') ? FontWeight.bold : FontWeight.normal,
      fontStyle: name.contains('Italic') || name.contains('Oblique')
          ? FontStyle.italic
          : FontStyle.normal,
      // metric scaling handles placement; kill extra spacing sources
      letterSpacing: 0,
      height: 1,
    );
  }

  static Color _toColor(PdfColor color, double alpha) => Color.from(
        alpha: alpha.clamp(0, 1),
        red: color.red.clamp(0, 1),
        green: color.green.clamp(0, 1),
        blue: color.blue.clamp(0, 1),
      );

  static ui.Path _toUiPath(PdfPath path, PdfFillRule rule) {
    final out = ui.Path()
      ..fillType = rule == PdfFillRule.evenOdd
          ? PathFillType.evenOdd
          : PathFillType.nonZero;
    for (final segment in path.segments) {
      switch (segment) {
        case PdfMoveTo(:final x, :final y):
          out.moveTo(x, y);
        case PdfLineTo(:final x, :final y):
          out.lineTo(x, y);
        case PdfCubicTo():
          out.cubicTo(segment.x1, segment.y1, segment.x2, segment.y2,
              segment.x3, segment.y3);
        case PdfClosePath():
          out.close();
      }
    }
    return out;
  }

  static Float64List _toFloat64(PdfMatrix m) => Float64List.fromList([
        m.a, m.b, 0, 0, //
        m.c, m.d, 0, 0, //
        0, 0, 1, 0, //
        m.e, m.f, 0, 1,
      ]);
}
