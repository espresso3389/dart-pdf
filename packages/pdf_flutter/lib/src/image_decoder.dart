import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

/// Collects every image a page references, without painting anything.
class ImageCollector implements PdfDevice {
  final List<CosStream> streams = [];

  @override
  void drawImage(PdfImageRequest request) => streams.add(request.stream);

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
  void strokePath(PdfPath path, PdfColor color, PdfStroke stroke, double a) {}
  @override
  void clipPath(PdfPath path, PdfFillRule rule) {}
  @override
  void drawText(PdfTextRun run) {}
}

/// Decodes image XObjects to [ui.Image]s ahead of the (synchronous) paint.
///
/// Coverage: DCTDecode via the platform codec; Flate/raw DeviceRGB,
/// DeviceGray (8 and 1 bit) and 8-bit Indexed samples; /SMask soft-mask
/// alpha; /ImageMask stencils (decoded as alpha, tinted by the device).
/// TODO: JPXDecode, CCITT/JBIG2, /Mask color-key masking, /Decode arrays
/// for non-stencil images.
Future<Map<CosStream, ui.Image>> decodeImages(
    CosDocument cos, Iterable<CosStream> streams) async {
  final out = <CosStream, ui.Image>{};
  for (final stream in streams) {
    if (out.containsKey(stream)) continue;
    try {
      final image = await _decodeOne(cos, stream);
      if (image != null) out[stream] = image;
    } on Exception {
      // undecodable image: the device will skip it
    }
  }
  return out;
}

Future<ui.Image?> _decodeOne(CosDocument cos, CosStream stream) async {
  final dict = stream.dictionary;
  final filters = _filterNames(cos, dict);
  final isMask = cos.resolve(dict['ImageMask']) == const CosBoolean(true);

  if (!isMask && (filters.contains('DCTDecode') || filters.contains('DCT'))) {
    // hand the JPEG straight to the platform codec
    final codec = await ui.instantiateImageCodec(stream.rawBytes);
    final base = (await codec.getNextFrame()).image;
    final mask = await _softMaskOf(cos, dict);
    if (mask == null) return base;
    final raw = await base.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) return base;
    final rgba = Uint8List.fromList(raw.buffer.asUint8List());
    _applyAlpha(rgba, base.width, base.height, mask);
    return _imageFromPixels(rgba, base.width, base.height);
  }
  if (filters.contains('JPXDecode') ||
      filters.contains('CCITTFaxDecode') ||
      filters.contains('JBIG2Decode')) {
    return null;
  }

  final width = _intOf(cos.resolve(dict['Width']));
  final height = _intOf(cos.resolve(dict['Height']));
  if (width <= 0 || height <= 0) return null;
  final bits = _intOf(cos.resolve(dict['BitsPerComponent']), fallback: 8);
  final data = cos.decodeStreamData(stream);

  final rgba = isMask
      ? _stencilToRgba(cos, dict, data, width, height)
      : _toRgba(cos, dict, data, width, height, bits);
  if (rgba == null) return null;

  if (!isMask) {
    final mask = await _softMaskOf(cos, dict);
    if (mask != null) _applyAlpha(rgba, width, height, mask);
  }
  return _imageFromPixels(rgba, width, height);
}

Future<ui.Image> _imageFromPixels(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// A stencil mask carries no colors: 1-bit samples select where the fill
/// color paints. Decode to white pixels with alpha; the device tints them.
/// Default /Decode [0 1] paints where the sample is 0 (§8.9.6.2).
Uint8List? _stencilToRgba(CosDocument cos, CosDictionary dict, Uint8List data,
    int width, int height) {
  final decode = cos.resolve(dict['Decode']);
  final inverted = decode is CosArray &&
      decode.length > 0 &&
      _numOf(cos.resolve(decode[0])) == 1;

  final out = Uint8List(width * height * 4);
  final rowBytes = (width + 7) ~/ 8;
  if (data.length < rowBytes * height) return null;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final bit = (data[y * rowBytes + (x >> 3)] >> (7 - (x & 7))) & 1;
      final paints = inverted ? bit == 1 : bit == 0;
      final i = (y * width + x) * 4;
      out[i] = out[i + 1] = out[i + 2] = 255;
      out[i + 3] = paints ? 255 : 0;
    }
  }
  return out;
}

class _SoftMask {
  const _SoftMask(this.alpha, this.width, this.height);
  final Uint8List alpha;
  final int width;
  final int height;
}

/// Decodes a /SMask: a grayscale image whose samples become the alpha
/// channel of its parent image (§11.6.5.2).
Future<_SoftMask?> _softMaskOf(CosDocument cos, CosDictionary dict) async {
  final smask = cos.resolve(dict['SMask']);
  if (smask is! CosStream) return null;
  try {
    final filters = _filterNames(cos, smask.dictionary);
    if (filters.contains('DCTDecode')) {
      final codec = await ui.instantiateImageCodec(smask.rawBytes);
      final image = (await codec.getNextFrame()).image;
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) return null;
      final rgba = raw.buffer.asUint8List();
      final alpha = Uint8List(image.width * image.height);
      for (var i = 0; i < alpha.length; i++) {
        alpha[i] = rgba[i * 4]; // gray: any channel works
      }
      return _SoftMask(alpha, image.width, image.height);
    }

    final width = _intOf(cos.resolve(smask.dictionary['Width']));
    final height = _intOf(cos.resolve(smask.dictionary['Height']));
    if (width <= 0 || height <= 0) return null;
    final bits =
        _intOf(cos.resolve(smask.dictionary['BitsPerComponent']), fallback: 8);
    final data = cos.decodeStreamData(smask);

    if (bits == 8 && data.length >= width * height) {
      return _SoftMask(data, width, height);
    }
    if (bits == 1) {
      final rowBytes = (width + 7) ~/ 8;
      if (data.length < rowBytes * height) return null;
      final alpha = Uint8List(width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final bit = (data[y * rowBytes + (x >> 3)] >> (7 - (x & 7))) & 1;
          alpha[y * width + x] = bit == 1 ? 255 : 0;
        }
      }
      return _SoftMask(alpha, width, height);
    }
    return null;
  } on Exception {
    return null; // unsupported mask: leave the image opaque
  }
}

/// Writes [mask] into the alpha channel of [rgba], resampling
/// nearest-neighbor when dimensions differ.
void _applyAlpha(Uint8List rgba, int width, int height, _SoftMask mask) {
  for (var y = 0; y < height; y++) {
    final maskY = y * mask.height ~/ height;
    for (var x = 0; x < width; x++) {
      final maskX = x * mask.width ~/ width;
      rgba[(y * width + x) * 4 + 3] = mask.alpha[maskY * mask.width + maskX];
    }
  }
}

Uint8List? _toRgba(CosDocument cos, CosDictionary dict, Uint8List data,
    int width, int height, int bits) {
  final count = width * height;
  final out = Uint8List(count * 4);

  final space = _colorSpaceOf(cos, dict);

  if (space == 'DeviceGray' && bits == 1) {
    final rowBytes = (width + 7) ~/ 8;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final byte = data[y * rowBytes + (x >> 3)];
        final on = (byte >> (7 - (x & 7))) & 1;
        final value = on == 1 ? 255 : 0;
        final i = (y * width + x) * 4;
        out[i] = out[i + 1] = out[i + 2] = value;
        out[i + 3] = 255;
      }
    }
    return out;
  }
  if (bits != 8) return null;

  switch (space) {
    case 'DeviceRGB':
      if (data.length < count * 3) return null;
      for (var i = 0; i < count; i++) {
        out[i * 4] = data[i * 3];
        out[i * 4 + 1] = data[i * 3 + 1];
        out[i * 4 + 2] = data[i * 3 + 2];
        out[i * 4 + 3] = 255;
      }
      return out;
    case 'DeviceGray':
      if (data.length < count) return null;
      for (var i = 0; i < count; i++) {
        out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = data[i];
        out[i * 4 + 3] = 255;
      }
      return out;
    case 'DeviceCMYK':
      if (data.length < count * 4) return null;
      for (var i = 0; i < count; i++) {
        final c = data[i * 4] / 255, m = data[i * 4 + 1] / 255;
        final y = data[i * 4 + 2] / 255, k = data[i * 4 + 3] / 255;
        out[i * 4] = ((1 - c) * (1 - k) * 255).round();
        out[i * 4 + 1] = ((1 - m) * (1 - k) * 255).round();
        out[i * 4 + 2] = ((1 - y) * (1 - k) * 255).round();
        out[i * 4 + 3] = 255;
      }
      return out;
    case 'Indexed':
      return _indexedToRgba(cos, dict, data, count, out);
  }
  return null;
}

Uint8List? _indexedToRgba(CosDocument cos, CosDictionary dict, Uint8List data,
    int count, Uint8List out) {
  final space = cos.resolve(dict['ColorSpace']);
  if (space is! CosArray || space.length < 4) return null;
  final base = cos.resolve(space[1]);
  final baseName = base is CosName ? base.value : '';
  if (baseName != 'DeviceRGB' && baseName != 'RGB') return null;
  final lookupObj = cos.resolve(space[3]);
  final Uint8List palette;
  if (lookupObj is CosString) {
    palette = lookupObj.bytes;
  } else if (lookupObj is CosStream) {
    palette = cos.decodeStreamData(lookupObj);
  } else {
    return null;
  }
  if (data.length < count) return null;
  for (var i = 0; i < count; i++) {
    final p = data[i] * 3;
    out[i * 4] = p < palette.length ? palette[p] : 0;
    out[i * 4 + 1] = p + 1 < palette.length ? palette[p + 1] : 0;
    out[i * 4 + 2] = p + 2 < palette.length ? palette[p + 2] : 0;
    out[i * 4 + 3] = 255;
  }
  return out;
}

String _colorSpaceOf(CosDocument cos, CosDictionary dict) {
  final space = cos.resolve(dict['ColorSpace']);
  if (space is CosName) {
    return switch (space.value) {
      'G' => 'DeviceGray',
      'RGB' => 'DeviceRGB',
      'CMYK' => 'DeviceCMYK',
      'I' => 'Indexed',
      final name => name,
    };
  }
  if (space is CosArray && space.length > 0) {
    final family = cos.resolve(space[0]);
    if (family is CosName) {
      if (family.value == 'Indexed' || family.value == 'I') return 'Indexed';
      if (family.value == 'ICCBased' && space.length > 1) {
        final profile = cos.resolve(space[1]);
        if (profile is CosStream) {
          final n = cos.resolve(profile.dictionary['N']);
          return switch (_intOf(n)) {
            1 => 'DeviceGray',
            4 => 'DeviceCMYK',
            _ => 'DeviceRGB',
          };
        }
      }
    }
  }
  return 'DeviceGray';
}

List<String> _filterNames(CosDocument cos, CosDictionary dict) {
  final filter = cos.resolve(dict['Filter']);
  if (filter is CosName) return [filter.value];
  if (filter is CosArray) {
    return [
      for (final f in filter.items)
        if (cos.resolve(f) case CosName(:final value)) value,
    ];
  }
  return const [];
}

double _numOf(CosObject? value) {
  if (value is CosInteger) return value.value.toDouble();
  if (value is CosReal) return value.value;
  return 0;
}

int _intOf(CosObject? value, {int fallback = 0}) =>
    value is CosInteger ? value.value : fallback;
