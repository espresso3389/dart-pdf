import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';

/// A PDF function (§7.10) restricted to one input — what shadings need.
///
/// Types 0 (sampled), 2 (exponential), and 3 (stitching) are supported;
/// type 4 (PostScript calculator) is a TODO and parses to null.
abstract class PdfFunction {
  const PdfFunction();

  List<double> evaluate(double x);

  static PdfFunction? parse(CosDocument cos, CosObject? object) {
    final resolved = cos.resolve(object);
    if (resolved is CosArray) {
      // one single-output function per color component
      final parts = <PdfFunction>[];
      for (final item in resolved.items) {
        final part = parse(cos, item);
        if (part == null) return null;
        parts.add(part);
      }
      return _CombinedFunction(parts);
    }

    final CosDictionary dict;
    if (resolved is CosStream) {
      dict = resolved.dictionary;
    } else if (resolved is CosDictionary) {
      dict = resolved;
    } else {
      return null;
    }

    final domain = _numbers(cos, dict['Domain']);
    final x0 = domain.isNotEmpty ? domain[0] : 0.0;
    final x1 = domain.length > 1 ? domain[1] : 1.0;

    final type = cos.resolve(dict['FunctionType']);
    switch (type is CosInteger ? type.value : -1) {
      case 2:
        final c0 = _numbers(cos, dict['C0']);
        final c1 = _numbers(cos, dict['C1']);
        final n = _number(cos, dict['N'], 1);
        return _ExponentialFunction(
          x0,
          x1,
          c0.isEmpty ? const [0] : c0,
          c1.isEmpty ? const [1] : c1,
          n,
        );
      case 3:
        final functions = cos.resolve(dict['Functions']);
        if (functions is! CosArray) return null;
        final parts = <PdfFunction>[];
        for (final item in functions.items) {
          final part = parse(cos, item);
          if (part == null) return null;
          parts.add(part);
        }
        return _StitchingFunction(
          x0,
          x1,
          parts,
          _numbers(cos, dict['Bounds']),
          _numbers(cos, dict['Encode']),
        );
      case 0:
        if (resolved is! CosStream) return null;
        final size = _numbers(cos, dict['Size']);
        final range = _numbers(cos, dict['Range']);
        final bits = _number(cos, dict['BitsPerSample'], 8).toInt();
        if (size.isEmpty || range.isEmpty) return null;
        final Uint8List data;
        try {
          data = cos.decodeStreamData(resolved);
        } on Exception {
          return null;
        }
        final encode = _numbers(cos, dict['Encode']);
        final decode = _numbers(cos, dict['Decode']);
        return _SampledFunction(
          x0,
          x1,
          data,
          size[0].toInt(),
          bits,
          range,
          encode.isEmpty ? [0, size[0] - 1] : encode,
          decode.isEmpty ? range : decode,
        );
      default:
        return null; // type 4 (PostScript calculator): TODO
    }
  }

  static double _number(CosDocument cos, CosObject? object, double fallback) {
    final v = cos.resolve(object);
    if (v is CosInteger) return v.value.toDouble();
    if (v is CosReal) return v.value;
    return fallback;
  }

  static List<double> _numbers(CosDocument cos, CosObject? object) {
    final v = cos.resolve(object);
    if (v is! CosArray) return const [];
    return [
      for (final item in v.items)
        switch (cos.resolve(item)) {
          CosInteger(:final value) => value.toDouble(),
          CosReal(:final value) => value,
          _ => 0.0,
        },
    ];
  }
}

class _CombinedFunction extends PdfFunction {
  const _CombinedFunction(this.parts);

  final List<PdfFunction> parts;

  @override
  List<double> evaluate(double x) =>
      [for (final part in parts) ...part.evaluate(x)];
}

class _ExponentialFunction extends PdfFunction {
  const _ExponentialFunction(this.x0, this.x1, this.c0, this.c1, this.n);

  final double x0, x1;
  final List<double> c0, c1;
  final double n;

  @override
  List<double> evaluate(double x) {
    final t = (x.clamp(x0, x1) - x0) / (x1 == x0 ? 1 : x1 - x0);
    final tn = math.pow(t, n).toDouble();
    final count = math.max(c0.length, c1.length);
    return [
      for (var i = 0; i < count; i++)
        _at(c0, i) + tn * (_at(c1, i) - _at(c0, i)),
    ];
  }

  static double _at(List<double> list, int i) =>
      i < list.length ? list[i] : 0;
}

class _StitchingFunction extends PdfFunction {
  const _StitchingFunction(
      this.x0, this.x1, this.functions, this.bounds, this.encode);

  final double x0, x1;
  final List<PdfFunction> functions;
  final List<double> bounds;
  final List<double> encode;

  @override
  List<double> evaluate(double x) {
    final clamped = x.clamp(x0, x1);
    var index = 0;
    while (index < bounds.length && clamped >= bounds[index]) {
      index++;
    }
    index = index.clamp(0, functions.length - 1);
    final low = index == 0 ? x0 : bounds[index - 1];
    final high = index < bounds.length ? bounds[index] : x1;
    final e0 = index * 2 < encode.length ? encode[index * 2] : 0.0;
    final e1 = index * 2 + 1 < encode.length ? encode[index * 2 + 1] : 1.0;
    final t = high == low ? e0 : e0 + (clamped - low) / (high - low) * (e1 - e0);
    return functions[index].evaluate(t);
  }
}

class _SampledFunction extends PdfFunction {
  const _SampledFunction(this.x0, this.x1, this.data, this.sampleCount,
      this.bitsPerSample, this.range, this.encode, this.decode);

  final double x0, x1;
  final Uint8List data;
  final int sampleCount;
  final int bitsPerSample;
  final List<double> range;
  final List<double> encode;
  final List<double> decode;

  int get _outputs => range.length ~/ 2;

  @override
  List<double> evaluate(double x) {
    if (sampleCount <= 0 || _outputs == 0) return const [0];
    final t = (x.clamp(x0, x1) - x0) / (x1 == x0 ? 1 : x1 - x0);
    final e0 = encode.isNotEmpty ? encode[0] : 0.0;
    final e1 = encode.length > 1 ? encode[1] : sampleCount - 1.0;
    final position = (e0 + t * (e1 - e0)).clamp(0.0, sampleCount - 1.0);
    // nearest-sample lookup; linear interpolation is a refinement TODO
    final index = position.round();
    final max = (1 << bitsPerSample) - 1;
    return [
      for (var output = 0; output < _outputs; output++)
        _decodeValue(
            _sampleAt(index * _outputs + output) / max, output),
    ];
  }

  double _decodeValue(double normalized, int output) {
    final d0 = output * 2 < decode.length ? decode[output * 2] : 0.0;
    final d1 = output * 2 + 1 < decode.length ? decode[output * 2 + 1] : 1.0;
    return d0 + normalized * (d1 - d0);
  }

  double _sampleAt(int sampleIndex) {
    final bitOffset = sampleIndex * bitsPerSample;
    var value = 0;
    for (var i = 0; i < bitsPerSample; i++) {
      final bit = bitOffset + i;
      final byte = bit >> 3;
      if (byte >= data.length) return 0;
      value = (value << 1) | ((data[byte] >> (7 - (bit & 7))) & 1);
    }
    return value.toDouble();
  }
}
