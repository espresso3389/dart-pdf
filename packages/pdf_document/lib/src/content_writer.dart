import 'dart:convert';
import 'dart:typed_data';

/// Builds content-stream bytes operator by operator.
///
/// Coordinates are PDF user space. Output is plain Latin-1 text; characters
/// outside Latin-1 in shown text degrade to '?' (appearance streams are
/// authored with WinAnsi-encoded base-14 fonts for now).
class ContentWriter {
  final StringBuffer _buffer = StringBuffer();

  void op(String operator, [List<double> operands = const []]) {
    for (final value in operands) {
      _buffer
        ..write(fmt(value))
        ..write(' ');
    }
    _buffer
      ..write(operator)
      ..write('\n');
  }

  void save() => op('q');
  void restore() => op('Q');

  /// References /[name] in the resources' /ExtGState dictionary.
  void extGState(String name) => _buffer.write('/$name gs\n');

  void fillColor(int rgb) => op('rg', rgbComponents(rgb));
  void strokeColor(int rgb) => op('RG', rgbComponents(rgb));
  void lineWidth(double width) => op('w', [width]);

  /// Round caps and joins — the right look for freehand ink strokes.
  void roundLines() {
    op('J', [1]);
    op('j', [1]);
  }

  void moveTo(double x, double y) => op('m', [x, y]);
  void lineTo(double x, double y) => op('l', [x, y]);
  void curveTo(double x1, double y1, double x2, double y2, double x3,
          double y3) =>
      op('c', [x1, y1, x2, y2, x3, y3]);
  void closePath() => op('h');
  void rect(double x, double y, double width, double height) =>
      op('re', [x, y, width, height]);

  /// Magic number for approximating a quarter circle with one Bézier.
  static const _kappa = 0.5522847498307936;

  void ellipse(double cx, double cy, double rx, double ry) {
    final kx = rx * _kappa;
    final ky = ry * _kappa;
    moveTo(cx + rx, cy);
    curveTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
    curveTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
    curveTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
    curveTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
    closePath();
  }

  void roundedRect(
      double x, double y, double width, double height, double radius) {
    final r = radius.clamp(0.0, width / 2).clamp(0.0, height / 2);
    final k = r * _kappa;
    moveTo(x + r, y);
    lineTo(x + width - r, y);
    curveTo(x + width - r + k, y, x + width, y + r - k, x + width, y + r);
    lineTo(x + width, y + height - r);
    curveTo(x + width, y + height - r + k, x + width - r + k, y + height,
        x + width - r, y + height);
    lineTo(x + r, y + height);
    curveTo(x + r - k, y + height, x, y + height - r + k, x, y + height - r);
    lineTo(x, y + r);
    curveTo(x, y + r - k, x + r - k, y, x + r, y);
    closePath();
  }

  void fill() => op('f');
  void stroke() => op('S');
  void fillAndStroke() => op('B');
  void clip() {
    op('W');
    op('n');
  }

  void beginText() => op('BT');
  void endText() => op('ET');

  /// References /[name] in the resources' /Font dictionary.
  void font(String name, double size) => _buffer.write('/$name ${fmt(size)} Tf\n');

  void leading(double value) => op('TL', [value]);
  void textAt(double x, double y) => op('Td', [x, y]);

  void showText(String text) {
    _buffer.write('(');
    for (final code in text.codeUnits) {
      switch (code) {
        case 0x28 || 0x29 || 0x5C: // ( ) \
          _buffer
            ..write('\\')
            ..writeCharCode(code);
        case 0x0A:
          _buffer.write('\\n');
        case 0x0D:
          _buffer.write('\\r');
        default:
          _buffer.writeCharCode(code <= 0xFF ? code : 0x3F /* ? */);
      }
    }
    _buffer.write(') Tj\n');
  }

  void nextLine() => op('T*');

  /// References /[name] in the resources' /XObject dictionary.
  void drawXObject(String name) => _buffer.write('/$name Do\n');

  void concatMatrix(
          double a, double b, double c, double d, double e, double f) =>
      op('cm', [a, b, c, d, e, f]);

  Uint8List takeBytes() =>
      Uint8List.fromList(latin1.encode(_buffer.toString()));

  static List<double> rgbComponents(int rgb) => [
        ((rgb >> 16) & 0xFF) / 255,
        ((rgb >> 8) & 0xFF) / 255,
        (rgb & 0xFF) / 255,
      ];

  /// Formats a number the way content streams like them: no exponent,
  /// no trailing zeros.
  static String fmt(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e9) {
      return value.toInt().toString();
    }
    var s = value.toStringAsFixed(3);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }
}

/// AFM advance widths for Helvetica, characters 32–126, in thousandths of
/// an em (Adobe base-14 metrics).
const List<int> helveticaWidths = [
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, //
  278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, //
  584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, //
  500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, //
  667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, //
  278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, //
  278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
];

/// AFM advance widths for Helvetica-Bold, characters 32–126.
const List<int> helveticaBoldWidths = [
  278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, //
  278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, //
  584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, //
  556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, //
  667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, //
  333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, //
  333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
];

/// Measures [text] in points at [fontSize], using base-14 Helvetica
/// metrics. Characters outside 32–126 count as an average width.
double measureHelvetica(String text, double fontSize, {bool bold = false}) {
  final table = bold ? helveticaBoldWidths : helveticaWidths;
  var total = 0;
  for (final code in text.codeUnits) {
    total += code >= 32 && code <= 126 ? table[code - 32] : 556;
  }
  return total * fontSize / 1000;
}
