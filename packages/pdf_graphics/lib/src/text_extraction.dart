import 'dart:math' as math;

import 'package:pdf_document/pdf_document.dart';

import 'color.dart';
import 'device.dart';
import 'interpreter.dart';
import 'matrix.dart';
import 'mesh.dart';
import 'path.dart';
import 'shading.dart';

/// One positioned run of text on a page, in page space.
class PdfExtractedRun {
  const PdfExtractedRun({
    required this.text,
    required this.startIndex,
    required this.transform,
    required this.width,
    required this.bounds,
  });

  final String text;

  /// Offset of [text] inside the owning [PdfPageText.text].
  final int startIndex;

  /// Em space → page space (see [PdfTextRun.transform]).
  final PdfMatrix transform;

  /// Advance width in em units.
  final double width;

  /// Page-space bounding box.
  final PdfRect bounds;
}

/// One search hit, with page-space rectangles for highlighting.
class PdfTextMatch {
  const PdfTextMatch({
    required this.pageIndex,
    required this.start,
    required this.end,
    required this.rects,
  });

  final int pageIndex;
  final int start;
  final int end;
  final List<PdfRect> rects;
}

/// The text content of one page, with geometry for search highlighting.
class PdfPageText {
  const PdfPageText({
    required this.pageIndex,
    required this.text,
    required this.runs,
  });

  final int pageIndex;
  final String text;
  final List<PdfExtractedRun> runs;

  /// Finds non-overlapping occurrences of [query].
  List<PdfTextMatch> findAll(String query, {bool caseSensitive = false}) {
    if (query.isEmpty) return const [];
    final haystack = caseSensitive ? text : text.toLowerCase();
    final needle = caseSensitive ? query : query.toLowerCase();
    final matches = <PdfTextMatch>[];
    var from = 0;
    while (true) {
      final index = haystack.indexOf(needle, from);
      if (index < 0) break;
      final end = index + needle.length;
      matches.add(PdfTextMatch(
        pageIndex: pageIndex,
        start: index,
        end: end,
        rects: rectsFor(index, end),
      ));
      from = end;
    }
    return matches;
  }

  /// Page-space rectangles covering the characters [start]..[end] of
  /// [text] — for search and selection highlights.
  List<PdfRect> rectsFor(int start, int end) {
    final rects = <PdfRect>[];
    for (final run in runs) {
      if (run.text.isEmpty) continue;
      final runEnd = run.startIndex + run.text.length;
      final overlapStart = math.max(start, run.startIndex);
      final overlapEnd = math.min(end, runEnd);
      if (overlapStart >= overlapEnd) continue;
      // approximate within-run positions by character fraction; per-glyph
      // geometry arrives with the font engine
      final f0 = (overlapStart - run.startIndex) / run.text.length;
      final f1 = (overlapEnd - run.startIndex) / run.text.length;
      rects.add(_boundsOf(run.transform, run.width * f0, run.width * f1));
    }
    return rects;
  }

  /// The page text inside [rect] (page space): runs whose bounds center
  /// falls within the rect, in document order, joined with single
  /// spaces. The text a /Link annotation's rectangle covers, for one.
  String textIn(PdfRect rect) {
    final parts = <(int, String)>[];
    for (final run in runs) {
      final piece = run.text.trim();
      if (piece.isEmpty) continue;
      final b = run.bounds;
      if (rect.contains((b.left + b.right) / 2, (b.bottom + b.top) / 2)) {
        parts.add((run.startIndex, piece));
      }
    }
    parts.sort((a, b) => a.$1.compareTo(b.$1));
    return parts.map((part) => part.$2).join(' ');
  }

  /// Index into [text] nearest the page-space point ([x], [y]), for
  /// mapping pointer positions to text positions (selection).
  ///
  /// Returns -1 when the document has no text or the nearest run is more
  /// than [tolerance] page units away.
  int positionNear(double x, double y, {double tolerance = double.infinity}) {
    PdfExtractedRun? best;
    var bestDistance = double.infinity;
    for (final run in runs) {
      if (run.text.isEmpty) continue;
      final b = run.bounds;
      final dx = math.max(0.0, math.max(b.left - x, x - b.right));
      final dy = math.max(0.0, math.max(b.bottom - y, y - b.top));
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = run;
      }
    }
    if (best == null || bestDistance > tolerance * tolerance) return -1;
    // fraction along the run's baseline, in em space
    final inverse = best.transform.inverted();
    final ex = inverse == null ? 0.0 : inverse.transformX(x, y);
    final fraction =
        best.width > 0 ? (ex / best.width).clamp(0.0, 1.0) : 0.0;
    return best.startIndex + (fraction * best.text.length).round();
  }
}

/// Extracts positioned text by running the interpreter with a collecting
/// device — the same code path rendering uses, so what you search is what
/// you see.
class PdfTextExtractor {
  PdfTextExtractor._();

  static PdfPageText extract(PdfDocument document, int pageIndex) {
    final device = _ExtractionDevice();
    PdfInterpreter(cos: document.cos, device: device)
        .drawPage(document.page(pageIndex));

    final buffer = StringBuffer();
    final runs = <PdfExtractedRun>[];
    PdfTextRun? previous;
    for (final run in device.runs) {
      if (previous != null) {
        buffer.write(_separator(previous, run));
      }
      final start = buffer.length;
      buffer.write(run.text);
      runs.add(PdfExtractedRun(
        text: run.text,
        startIndex: start,
        transform: run.transform,
        width: run.width,
        bounds: _boundsOf(run.transform, 0, run.width),
      ));
      previous = run;
    }
    return PdfPageText(
        pageIndex: pageIndex, text: buffer.toString(), runs: runs);
  }

  /// Joins consecutive runs: nothing when they abut (kerning splits inside a
  /// word), a space within a line, a newline on baseline changes.
  static String _separator(PdfTextRun previous, PdfTextRun next) {
    final em = previous.transform.scaleFactor;
    if (em <= 0) return ' ';
    final endX = previous.transform.transformX(previous.width, 0);
    final endY = previous.transform.transformY(previous.width, 0);
    final dx = next.transform.e - endX;
    final dy = next.transform.f - endY;
    if (dy.abs() > 0.5 * em) return '\n';
    if (dx.abs() > 0.15 * em) return ' ';
    return '';
  }
}

/// Bounding box of the em-space span [x0]..[x1] (with conventional 0.25 em
/// descent and 0.75 em ascent) mapped through [transform].
PdfRect _boundsOf(PdfMatrix transform, double x0, double x1) {
  const descent = -0.25;
  const ascent = 0.75;
  final xs = <double>[];
  final ys = <double>[];
  for (final (x, y) in [
    (x0, descent),
    (x1, descent),
    (x0, ascent),
    (x1, ascent),
  ]) {
    xs.add(transform.transformX(x, y));
    ys.add(transform.transformY(x, y));
  }
  return PdfRect(
    xs.reduce(math.min),
    ys.reduce(math.min),
    xs.reduce(math.max),
    ys.reduce(math.max),
  );
}

class _ExtractionDevice implements PdfDevice {
  final List<PdfTextRun> runs = [];

  @override
  void drawText(PdfTextRun run) => runs.add(run);

  @override
  void save() {}
  @override
  void restore() {}
  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double a) {}
  @override
  void fillPathGradient(
      PdfPath path, PdfFillRule rule, PdfGradient gradient, double a) {}
  @override
  void fillMesh(PdfMesh mesh, double a) {}
  @override
  void strokePath(PdfPath path, PdfColor color, PdfStroke stroke, double a) {}
  @override
  void clipPath(PdfPath path, PdfFillRule rule) {}
  @override
  void drawImage(PdfImageRequest request) {}

  @override
  void setBlendMode(PdfBlendMode mode) {}
  @override
  void beginGroup(double alpha) {}
  @override
  void endGroup() {}
  @override
  void beginSoftMasked() {}
  @override
  void endSoftMasked(
      {required bool luminosity,
      required PdfRect backdrop,
      required void Function() drawMask}) {}
}
