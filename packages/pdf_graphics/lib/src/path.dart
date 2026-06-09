/// Path geometry emitted by the interpreter. Coordinates are already
/// transformed into page space (PDF default user space, y-up), because PDF
/// applies the CTM at path-construction time.
sealed class PdfPathSegment {
  const PdfPathSegment();
}

class PdfMoveTo extends PdfPathSegment {
  const PdfMoveTo(this.x, this.y);
  final double x;
  final double y;
}

class PdfLineTo extends PdfPathSegment {
  const PdfLineTo(this.x, this.y);
  final double x;
  final double y;
}

class PdfCubicTo extends PdfPathSegment {
  const PdfCubicTo(this.x1, this.y1, this.x2, this.y2, this.x3, this.y3);
  final double x1, y1, x2, y2, x3, y3;
}

class PdfClosePath extends PdfPathSegment {
  const PdfClosePath();
}

class PdfPath {
  const PdfPath(this.segments);
  final List<PdfPathSegment> segments;
  bool get isEmpty => segments.isEmpty;
}

enum PdfFillRule { nonzero, evenOdd }

/// Stroke parameters, with width already scaled into page space.
class PdfStroke {
  const PdfStroke({
    this.width = 1,
    this.cap = 0,
    this.join = 0,
    this.miterLimit = 10,
    this.dashArray = const [],
    this.dashPhase = 0,
  });

  final double width;

  /// 0 = butt, 1 = round, 2 = projecting square (§8.4.3.3).
  final int cap;

  /// 0 = miter, 1 = round, 2 = bevel (§8.4.3.4).
  final int join;

  final double miterLimit;
  final List<double> dashArray;
  final double dashPhase;

  PdfStroke copyWith({
    double? width,
    int? cap,
    int? join,
    double? miterLimit,
    List<double>? dashArray,
    double? dashPhase,
  }) =>
      PdfStroke(
        width: width ?? this.width,
        cap: cap ?? this.cap,
        join: join ?? this.join,
        miterLimit: miterLimit ?? this.miterLimit,
        dashArray: dashArray ?? this.dashArray,
        dashPhase: dashPhase ?? this.dashPhase,
      );
}
