/// Interprets raw color components by count: 1 = gray, 3 = RGB, 4 = CMYK.
/// Used for sc/scn operands and shading function outputs.
PdfColor colorFromComponents(List<double> values, [int? count]) {
  final n = count ?? values.length;
  double at(int i) => i < values.length ? values[i].clamp(0, 1).toDouble() : 0;
  return switch (n) {
    1 => PdfColor.gray(at(0)),
    4 => PdfColor.cmyk(at(0), at(1), at(2), at(3)),
    _ => PdfColor(at(0), at(1), at(2)),
  };
}

/// An RGB color with components in 0..1, the renderer's common currency.
/// Device color spaces convert into it; ICC-based spaces approximate for now.
class PdfColor {
  const PdfColor(this.red, this.green, this.blue);

  const PdfColor.gray(double level) : this(level, level, level);

  /// CMYK as halftone ink coverage: each tint interpolates linearly from
  /// paper white toward its process ink's sRGB rendering, and inks
  /// multiply where they overprint. Much closer to profile-converted
  /// CMYK than the naive complement formula — pure cyan comes out as the
  /// printed #009EE0, not monitor cyan.
  factory PdfColor.cmyk(double c, double m, double y, double k) {
    // 1 - tint·(1 - inkChannel): white paper showing through tint% ink
    double ink(double tint, double channel) =>
        1 - tint.clamp(0.0, 1.0) * (1 - channel);
    final paper = 1 - k.clamp(0.0, 1.0);
    return PdfColor(
      ink(c, _cyanInk.red) * ink(m, _magentaInk.red) * ink(y, _yellowInk.red) * paper,
      ink(c, _cyanInk.green) * ink(m, _magentaInk.green) * ink(y, _yellowInk.green) * paper,
      ink(c, _cyanInk.blue) * ink(m, _magentaInk.blue) * ink(y, _yellowInk.blue) * paper,
    );
  }

  /// sRGB renderings of the SWOP-class process inks at full coverage.
  static const _cyanInk = PdfColor(0, 0.62, 0.878); // #009EE0
  static const _magentaInk = PdfColor(0.925, 0, 0.549); // #EC008C
  static const _yellowInk = PdfColor(1, 0.949, 0); // #FFF200

  static const PdfColor black = PdfColor(0, 0, 0);

  final double red;
  final double green;
  final double blue;

  @override
  bool operator ==(Object other) =>
      other is PdfColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue;

  @override
  int get hashCode => Object.hash(red, green, blue);

  @override
  String toString() => 'PdfColor($red, $green, $blue)';
}
