import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
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
  void fillMesh(PdfMesh mesh, double a) {}
  @override
  void strokePath(PdfPath path, PdfColor color, PdfStroke stroke, double a) {}
  @override
  void clipPath(PdfPath path, PdfFillRule rule) {}
  @override
  void drawText(PdfTextRun run) {}
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
      required void Function() drawMask}) {
    drawMask(); // mask groups can reference images that need decoding
  }
}

/// Decodes image XObjects to [ui.Image]s ahead of the (synchronous) paint.
///
/// Coverage: DCTDecode via the platform codec; Flate/raw DeviceRGB,
/// DeviceGray (8 and 1 bit) and Indexed samples (1/2/4/8 bit, palettes in
/// RGB, gray, or CMYK bases including ICCBased); /SMask soft-mask alpha;
/// explicit /Mask stencil streams; color-key /Mask ranges and /Decode
/// arrays (on raw samples and on platform-decoded JPEGs); /ImageMask
/// stencils (decoded as alpha, tinted by the device).
/// TODO: JPXDecode, CCITT/JBIG2 (no pure-Dart decoders yet).
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

  final dctName = filters.contains('DCTDecode')
      ? 'DCTDecode'
      : filters.contains('DCT')
          ? 'DCT'
          : null;
  if (!isMask && dctName != null) {
    // undo any wrapping filters (e.g. [/FlateDecode /DCTDecode]), then
    // hand the JPEG to the platform codec
    final jpeg = cos.decodeStreamData(stream, stopBeforeFilter: dctName);
    final codec = await ui.instantiateImageCodec(jpeg);
    final base = (await codec.getNextFrame()).image;
    final mask = await _softMaskOf(cos, dict) ?? _stencilMaskOf(cos, dict);
    // /Decode and color-key /Mask apply to the decoded samples; gray
    // JPEGs decode to RGBA with the sample replicated, so one channel
    // stands in for the raw sample either way
    final family = _colorSpaceOf(cos, dict);
    final components = switch (family) {
      'DeviceGray' => 1,
      'DeviceRGB' => 3,
      _ => 0,
    };
    final ranges =
        components > 0 ? _decodeRanges(cos, dict, components) : null;
    final colorKey =
        components > 0 ? _colorKeyRanges(cos, dict, components) : null;
    if (mask == null && ranges == null && colorKey == null) return base;
    final raw = await base.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) return base;
    final rgba = Uint8List.fromList(raw.buffer.asUint8List());
    if (ranges != null || colorKey != null) {
      _applyDecodeAndColorKey(rgba, components, ranges, colorKey);
    }
    if (mask != null) _applyAlpha(rgba, base.width, base.height, mask);
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
    final mask = await _softMaskOf(cos, dict) ?? _stencilMaskOf(cos, dict);
    if (mask != null) _applyAlpha(rgba, width, height, mask);
  }
  return _imageFromPixels(rgba, width, height);
}

/// An explicit /Mask stencil stream (§8.9.6.3): 1-bit samples where 1
/// means "masked out" (transparent); /Decode [1 0] flips the polarity.
_SoftMask? _stencilMaskOf(CosDocument cos, CosDictionary dict) {
  final mask = cos.resolve(dict['Mask']);
  if (mask is! CosStream) return null;
  try {
    final width = _intOf(cos.resolve(mask.dictionary['Width']));
    final height = _intOf(cos.resolve(mask.dictionary['Height']));
    if (width <= 0 || height <= 0) return null;
    final bits =
        _intOf(cos.resolve(mask.dictionary['BitsPerComponent']), fallback: 1);
    if (bits != 1) return null;
    final decode = cos.resolve(mask.dictionary['Decode']);
    final inverted = decode is CosArray &&
        decode.length > 0 &&
        _numOf(cos.resolve(decode[0])) == 1;
    final data = cos.decodeStreamData(mask);
    final rowBytes = (width + 7) ~/ 8;
    if (data.length < rowBytes * height) return null;
    final alpha = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final bit = (data[y * rowBytes + (x >> 3)] >> (7 - (x & 7))) & 1;
        final masked = inverted ? bit == 0 : bit == 1;
        alpha[y * width + x] = masked ? 0 : 255;
      }
    }
    return _SoftMask(alpha, width, height);
  } on Exception {
    return null; // unsupported mask: leave the image opaque
  }
}

/// Per-component (min, max) pairs from /Decode, or null when absent or
/// not matching [components].
List<(double, double)>? _decodeRanges(
    CosDocument cos, CosDictionary dict, int components) {
  final raw = cos.resolve(dict['Decode']);
  if (raw is! CosArray || raw.length < components * 2) return null;
  final values = <double>[];
  for (var i = 0; i < components * 2; i++) {
    final n = cos.resolve(raw[i]);
    if (n is CosInteger) {
      values.add(n.value.toDouble());
    } else if (n is CosReal) {
      values.add(n.value);
    } else {
      return null;
    }
  }
  final ranges = [
    for (var c = 0; c < components; c++) (values[c * 2], values[c * 2 + 1]),
  ];
  // identity decode: skip the lookup work
  if (ranges.every((r) => r.$1 == 0 && r.$2 == 1)) return null;
  return ranges;
}

/// A 256-entry lookup table mapping a raw 8-bit sample through a /Decode
/// range back to an 8-bit value.
Uint8List _decodeLut((double, double) range) {
  final (min, max) = range;
  final lut = Uint8List(256);
  for (var s = 0; s < 256; s++) {
    lut[s] = ((min + s / 255 * (max - min)) * 255).round().clamp(0, 255);
  }
  return lut;
}

/// Color-key masking ranges (§8.9.6.4): /Mask as an array of [min max]
/// pairs in *raw sample* space; samples inside every range go transparent.
List<(int, int)>? _colorKeyRanges(
    CosDocument cos, CosDictionary dict, int components) {
  final raw = cos.resolve(dict['Mask']);
  if (raw is! CosArray || raw.length < components * 2) return null;
  final values = <int>[];
  for (var i = 0; i < components * 2; i++) {
    final n = cos.resolve(raw[i]);
    if (n is! CosInteger) return null;
    values.add(n.value);
  }
  return [
    for (var c = 0; c < components; c++) (values[c * 2], values[c * 2 + 1]),
  ];
}

Future<ui.Image> _imageFromPixels(Uint8List rgba, int width, int height) {
  // decodeImageFromPixels treats rgba8888 as premultiplied; straight
  // alpha would make transparent-but-colored pixels (a white backdrop
  // under an /SMask cutout) composite additively as solid color
  for (var i = 0; i < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a == 255) continue;
    rgba[i] = rgba[i] * a ~/ 255;
    rgba[i + 1] = rgba[i + 1] * a ~/ 255;
    rgba[i + 2] = rgba[i + 2] * a ~/ 255;
  }
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
      final codec = await ui.instantiateImageCodec(
          cos.decodeStreamData(smask, stopBeforeFilter: 'DCTDecode'));
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

/// Applies a /Decode lookup and color-key transparency to RGBA pixels in
/// place. Keying compares the pre-/Decode samples (§8.9.6.4), so it runs
/// before the lookup.
void _applyDecodeAndColorKey(Uint8List rgba, int components,
    List<(double, double)>? ranges, List<(int, int)>? colorKey) {
  final luts = ranges == null
      ? null
      : [for (var c = 0; c < components; c++) _lutFor(ranges, c)];
  for (var i = 0; i < rgba.length; i += 4) {
    if (colorKey != null) {
      var inside = true;
      for (var c = 0; c < components; c++) {
        final sample = rgba[i + (components == 1 ? 0 : c)];
        if (sample < colorKey[c].$1 || sample > colorKey[c].$2) {
          inside = false;
          break;
        }
      }
      if (inside) rgba[i + 3] = 0;
    }
    if (luts != null) {
      if (components == 1) {
        rgba[i] = rgba[i + 1] = rgba[i + 2] = luts[0][rgba[i]];
      } else {
        rgba[i] = luts[0][rgba[i]];
        rgba[i + 1] = luts[1][rgba[i + 1]];
        rgba[i + 2] = luts[2][rgba[i + 2]];
      }
    }
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
  final components = switch (space) {
    'DeviceRGB' => 3,
    'DeviceGray' => 1,
    'DeviceCMYK' => 4,
    _ => 0,
  };
  final ranges =
      components > 0 ? _decodeRanges(cos, dict, components) : null;
  final colorKey = components > 0
      ? _colorKeyRanges(cos, dict, components)
      : space == 'Indexed'
          ? _colorKeyRanges(cos, dict, 1)
          : null;

  bool keyed(List<int> samples) {
    if (colorKey == null) return false;
    for (var c = 0; c < samples.length; c++) {
      if (samples[c] < colorKey[c].$1 || samples[c] > colorKey[c].$2) {
        return false;
      }
    }
    return true;
  }

  if (space == 'DeviceGray' && bits == 1) {
    final (min, max) = ranges?[0] ?? (0.0, 1.0);
    final values = [
      (min * 255).round().clamp(0, 255),
      (max * 255).round().clamp(0, 255),
    ];
    final rowBytes = (width + 7) ~/ 8;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final byte = data[y * rowBytes + (x >> 3)];
        final on = (byte >> (7 - (x & 7))) & 1;
        final i = (y * width + x) * 4;
        out[i] = out[i + 1] = out[i + 2] = values[on];
        out[i + 3] = keyed([on]) ? 0 : 255;
      }
    }
    return out;
  }
  if (space == 'Indexed') {
    return _indexedToRgba(cos, dict, data, width, height, bits, out,
        colorKey: colorKey);
  }
  if (bits != 8) return null;

  switch (space) {
    case 'DeviceRGB':
      if (data.length < count * 3) return null;
      final luts = [for (var c = 0; c < 3; c++) _lutFor(ranges, c)];
      for (var i = 0; i < count; i++) {
        final r = data[i * 3], g = data[i * 3 + 1], b = data[i * 3 + 2];
        out[i * 4] = luts[0][r];
        out[i * 4 + 1] = luts[1][g];
        out[i * 4 + 2] = luts[2][b];
        out[i * 4 + 3] = keyed([r, g, b]) ? 0 : 255;
      }
      return out;
    case 'DeviceGray':
      if (data.length < count) return null;
      final lut = _lutFor(ranges, 0);
      for (var i = 0; i < count; i++) {
        out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = lut[data[i]];
        out[i * 4 + 3] = keyed([data[i]]) ? 0 : 255;
      }
      return out;
    case 'DeviceCMYK':
      if (data.length < count * 4) return null;
      final luts = [for (var c = 0; c < 4; c++) _lutFor(ranges, c)];
      for (var i = 0; i < count; i++) {
        final s = [for (var c = 0; c < 4; c++) data[i * 4 + c]];
        final color = PdfColor.cmyk(luts[0][s[0]] / 255, luts[1][s[1]] / 255,
            luts[2][s[2]] / 255, luts[3][s[3]] / 255);
        out[i * 4] = (color.red * 255).round();
        out[i * 4 + 1] = (color.green * 255).round();
        out[i * 4 + 2] = (color.blue * 255).round();
        out[i * 4 + 3] = keyed(s) ? 0 : 255;
      }
      return out;
  }
  return null;
}

final Uint8List _identityLut =
    Uint8List.fromList([for (var i = 0; i < 256; i++) i]);

Uint8List _lutFor(List<(double, double)>? ranges, int component) =>
    ranges == null ? _identityLut : _decodeLut(ranges[component]);

/// Indexed images: samples are palette indices at 1/2/4/8 bits per pixel;
/// the palette lives in any base space we can map to RGB (DeviceRGB and
/// -Gray and -CMYK, directly or behind ICCBased/CalRGB/CalGray).
Uint8List? _indexedToRgba(CosDocument cos, CosDictionary dict, Uint8List data,
    int width, int height, int bits, Uint8List out,
    {List<(int, int)>? colorKey}) {
  final space = cos.resolve(dict['ColorSpace']);
  if (space is! CosArray || space.length < 4) return null;
  final components = switch (_familyOf(cos, space[1])) {
    'DeviceRGB' => 3,
    'DeviceGray' => 1,
    'DeviceCMYK' => 4,
    _ => 0,
  };
  if (components == 0) return null;
  if (bits != 1 && bits != 2 && bits != 4 && bits != 8) return null;

  final lookupObj = cos.resolve(space[3]);
  final Uint8List lookup;
  if (lookupObj is CosString) {
    lookup = lookupObj.bytes;
  } else if (lookupObj is CosStream) {
    lookup = cos.decodeStreamData(lookupObj);
  } else {
    return null;
  }
  // convert the palette to RGB once, indices then just copy triplets
  final paletteCount = lookup.length ~/ components;
  final palette = Uint8List(paletteCount * 3);
  for (var p = 0; p < paletteCount; p++) {
    final src = p * components;
    switch (components) {
      case 3:
        palette[p * 3] = lookup[src];
        palette[p * 3 + 1] = lookup[src + 1];
        palette[p * 3 + 2] = lookup[src + 2];
      case 1:
        palette[p * 3] = palette[p * 3 + 1] = palette[p * 3 + 2] = lookup[src];
      case 4:
        final color = PdfColor.cmyk(lookup[src] / 255, lookup[src + 1] / 255,
            lookup[src + 2] / 255, lookup[src + 3] / 255);
        palette[p * 3] = (color.red * 255).round();
        palette[p * 3 + 1] = (color.green * 255).round();
        palette[p * 3 + 2] = (color.blue * 255).round();
    }
  }

  final rowBytes = (width * bits + 7) ~/ 8;
  if (data.length < rowBytes * height) return null;
  final perByte = 8 ~/ bits;
  final mask = (1 << bits) - 1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final byte = data[y * rowBytes + x ~/ perByte];
      final shift = 8 - bits * (x % perByte + 1);
      final raw = (byte >> shift) & mask;
      final index = raw >= paletteCount ? 0 : raw;
      final i = (y * width + x) * 4;
      out[i] = palette[index * 3];
      out[i + 1] = palette[index * 3 + 1];
      out[i + 2] = palette[index * 3 + 2];
      // color-key ranges compare the raw index sample (§8.9.6.4)
      out[i + 3] = colorKey != null &&
              raw >= colorKey[0].$1 &&
              raw <= colorKey[0].$2
          ? 0
          : 255;
    }
  }
  return out;
}

String _colorSpaceOf(CosDocument cos, CosDictionary dict) =>
    _familyOf(cos, dict['ColorSpace']);

/// Maps any color-space object to the device family used for decoding:
/// names (with their inline-image abbreviations), ICCBased by component
/// count, and the CIE spaces by their device-family shape.
String _familyOf(CosDocument cos, CosObject? raw) {
  final space = cos.resolve(raw);
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
      switch (family.value) {
        case 'Indexed' || 'I':
          return 'Indexed';
        case 'CalRGB':
          return 'DeviceRGB';
        case 'CalGray':
          return 'DeviceGray';
        case 'ICCBased':
          if (space.length > 1) {
            final profile = cos.resolve(space[1]);
            if (profile is CosStream) {
              return switch (_intOf(cos.resolve(profile.dictionary['N']))) {
                1 => 'DeviceGray',
                4 => 'DeviceCMYK',
                _ => 'DeviceRGB',
              };
            }
          }
          return 'DeviceRGB';
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
