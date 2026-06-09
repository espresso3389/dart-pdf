import 'package:pdf_cos/pdf_cos.dart';

import 'color.dart';
import 'matrix.dart';
import 'path.dart';

/// One run of text from a single show-text operator.
class PdfTextRun {
  const PdfTextRun({
    required this.text,
    required this.transform,
    required this.color,
    required this.width,
    this.fontName,
    this.fontSize = 0,
  });

  /// Best-effort Unicode (via ToUnicode CMaps or the font's encoding).
  final String text;

  /// Maps em-space (origin at the baseline start, 1.0 = the font size) to
  /// page space. Includes font size, horizontal scaling, and rise.
  final PdfMatrix transform;

  final PdfColor color;

  /// Advance width in em units, from the PDF's font metrics. Devices should
  /// scale their substituted font's output to match, so columns line up.
  final double width;

  /// The /BaseFont name, e.g. `ABCDEF+Helvetica-Bold`.
  final String? fontName;

  /// Nominal font size before transformation, for font selection heuristics.
  final double fontSize;
}

/// An image draw request. Decoding is left to the device, which may have
/// platform codecs (and may need to be async — devices can pre-collect).
class PdfImageRequest {
  const PdfImageRequest({
    required this.stream,
    required this.transform,
    this.alpha = 1,
  });

  final CosStream stream;

  /// Maps the unit square (image space, y-up) to page space.
  final PdfMatrix transform;

  final double alpha;
}

/// Rendering target. The interpreter walks a content stream and emits these
/// callbacks; implementations include the Flutter Canvas device, a
/// text-extraction device, and test recorders.
abstract interface class PdfDevice {
  /// Mirrors `q`. Saved state must include the clip.
  void save();

  /// Mirrors `Q`.
  void restore();

  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha);

  void strokePath(PdfPath path, PdfColor color, PdfStroke stroke, double alpha);

  /// Intersects the current clip with [path].
  void clipPath(PdfPath path, PdfFillRule rule);

  void drawText(PdfTextRun run);

  void drawImage(PdfImageRequest request);
}
