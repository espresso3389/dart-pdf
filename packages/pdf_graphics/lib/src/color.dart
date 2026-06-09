/// An RGB color with components in 0..1, the renderer's common currency.
/// Device color spaces convert into it; ICC-based spaces approximate for now.
class PdfColor {
  const PdfColor(this.red, this.green, this.blue);

  const PdfColor.gray(double level) : this(level, level, level);

  factory PdfColor.cmyk(double c, double m, double y, double k) => PdfColor(
        (1 - c) * (1 - k),
        (1 - m) * (1 - k),
        (1 - y) * (1 - k),
      );

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
