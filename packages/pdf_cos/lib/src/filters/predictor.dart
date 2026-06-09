import 'dart:typed_data';

import '../exceptions.dart';
import '../objects.dart';

int _intParam(CosDictionary? params, String key, int fallback) {
  final v = params?[key];
  return v is CosInteger ? v.value : fallback;
}

/// Reverses the /Predictor transform described by a filter's /DecodeParms
/// (ISO 32000-1 §7.4.4.4). Returns [data] unchanged when no predictor is set.
Uint8List applyPredictor(Uint8List data, CosDictionary? params) {
  final predictor = _intParam(params, 'Predictor', 1);
  if (predictor <= 1) return data;

  final colors = _intParam(params, 'Colors', 1);
  final bitsPerComponent = _intParam(params, 'BitsPerComponent', 8);
  final columns = _intParam(params, 'Columns', 1);
  final bytesPerPixel = (colors * bitsPerComponent + 7) ~/ 8;
  final bytesPerRow = (colors * bitsPerComponent * columns + 7) ~/ 8;

  if (predictor == 2) {
    if (bitsPerComponent != 8) {
      throw CosParseException(
          'TIFF predictor with $bitsPerComponent bits per component '
          'is not supported yet');
    }
    for (var row = 0; row + bytesPerRow <= data.length; row += bytesPerRow) {
      for (var i = bytesPerPixel; i < bytesPerRow; i++) {
        data[row + i] = (data[row + i] + data[row + i - bytesPerPixel]) & 0xFF;
      }
    }
    return data;
  }

  // PNG predictors (10..15): every row is prefixed with a filter-type byte.
  final rowCount = data.length ~/ (bytesPerRow + 1);
  final out = Uint8List(rowCount * bytesPerRow);
  final prior = Uint8List(bytesPerRow);
  var inPos = 0;
  var outPos = 0;
  for (var r = 0; r < rowCount; r++) {
    final filter = data[inPos++];
    for (var i = 0; i < bytesPerRow; i++) {
      final raw = data[inPos + i];
      final left = i >= bytesPerPixel ? out[outPos + i - bytesPerPixel] : 0;
      final up = prior[i];
      final upLeft = i >= bytesPerPixel ? prior[i - bytesPerPixel] : 0;
      final int value;
      switch (filter) {
        case 0:
          value = raw;
        case 1:
          value = raw + left;
        case 2:
          value = raw + up;
        case 3:
          value = raw + ((left + up) >> 1);
        case 4:
          value = raw + _paeth(left, up, upLeft);
        default:
          throw CosParseException('invalid PNG predictor filter byte $filter');
      }
      out[outPos + i] = value & 0xFF;
    }
    inPos += bytesPerRow;
    prior.setRange(0, bytesPerRow, out, outPos);
    outPos += bytesPerRow;
  }
  return out;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}
