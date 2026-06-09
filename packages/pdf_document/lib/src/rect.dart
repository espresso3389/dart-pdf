/// A rectangle in PDF user space (origin bottom-left, y grows upward).
class PdfRect {
  const PdfRect(this.left, this.bottom, this.right, this.top);

  /// Builds a rect with corners sorted so width and height are non-negative,
  /// as required for boxes (§7.9.5).
  factory PdfRect.normalized(double x1, double y1, double x2, double y2) =>
      PdfRect(
        x1 < x2 ? x1 : x2,
        y1 < y2 ? y1 : y2,
        x1 < x2 ? x2 : x1,
        y1 < y2 ? y2 : y1,
      );

  final double left;
  final double bottom;
  final double right;
  final double top;

  double get width => right - left;
  double get height => top - bottom;

  PdfRect intersect(PdfRect other) => PdfRect(
        left > other.left ? left : other.left,
        bottom > other.bottom ? bottom : other.bottom,
        right < other.right ? right : other.right,
        top < other.top ? top : other.top,
      );

  @override
  bool operator ==(Object other) =>
      other is PdfRect &&
      other.left == left &&
      other.bottom == bottom &&
      other.right == right &&
      other.top == top;

  @override
  int get hashCode => Object.hash(left, bottom, right, top);

  @override
  String toString() => 'PdfRect($left, $bottom, $right, $top)';
}
