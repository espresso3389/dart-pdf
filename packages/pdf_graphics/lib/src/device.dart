import 'package:pdf_cos/pdf_cos.dart';

import 'color.dart';
import 'matrix.dart';
import 'path.dart';
import 'shading.dart';

/// One glyph within a [PdfTextRun]: its outline (when the font is embedded
/// and parsed) and its pen offset, both in em units.
class PdfGlyphPlacement {
  const PdfGlyphPlacement({required this.offset, this.outline});

  /// Horizontal pen position within the run, in em units.
  final double offset;

  /// Glyph outline in em units (y-up, origin on the baseline), or null when
  /// the glyph is blank or its outline could not be parsed.
  final PdfPath? outline;
}

/// One run of text from a single show-text operator.
class PdfTextRun {
  const PdfTextRun({
    required this.text,
    required this.transform,
    required this.color,
    required this.width,
    this.fontName,
    this.fontSize = 0,
    this.glyphs,
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

  /// Real glyph outlines from the embedded font, when available. Devices
  /// should prefer these over substituted text rendering.
  final List<PdfGlyphPlacement>? glyphs;

  bool get hasOutlines =>
      glyphs != null && glyphs!.any((g) => g.outline != null);
}

/// An image draw request. Decoding is left to the device, which may have
/// platform codecs (and may need to be async — devices can pre-collect).
class PdfImageRequest {
  const PdfImageRequest({
    required this.stream,
    required this.transform,
    this.alpha = 1,
    this.isStencil = false,
    this.stencilColor = PdfColor.black,
  });

  final CosStream stream;

  /// Maps the unit square (image space, y-up) to page space.
  final PdfMatrix transform;

  final double alpha;

  /// True for /ImageMask stencils, which paint [stencilColor] through the
  /// mask instead of carrying their own colors (§8.9.6.2).
  final bool isStencil;

  /// The fill color in effect when a stencil mask is drawn.
  final PdfColor stencilColor;
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

  /// Fills with a gradient (axial/radial shading patterns and `sh`).
  /// Non-painting devices can ignore it; simple devices may fall back to
  /// `fillPath` with [PdfGradient.averageColor].
  void fillPathGradient(
      PdfPath path, PdfFillRule rule, PdfGradient gradient, double alpha);

  void strokePath(PdfPath path, PdfColor color, PdfStroke stroke, double alpha);

  /// Intersects the current clip with [path].
  void clipPath(PdfPath path, PdfFillRule rule);

  void drawText(PdfTextRun run);

  void drawImage(PdfImageRequest request);
}
