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
  void strokePath(PdfPath path, PdfColor color, PdfStroke stroke, double a) {}
  @override
  void clipPath(PdfPath path, PdfFillRule rule) {}
  @override
  void drawText(PdfTextRun run) {}
}

/// Decodes image XObjects to [ui.Image]s ahead of the (synchronous) paint.
///
/// Coverage: DCTDecode via the platform codec; Flate/raw DeviceRGB,
/// DeviceGray (8 and 1 bit) and 8-bit Indexed samples.
/// TODO: JPXDecode, CCITT/JBIG2, /SMask transparency, /Decode arrays.
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

  if (filters.contains('DCTDecode') || filters.contains('DCT')) {
    // hand the JPEG straight to the platform codec
    final codec = await ui.instantiateImageCodec(stream.rawBytes);
    final frame = await codec.getNextFrame();
    return frame.image;
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

  final rgba = _toRgba(cos, dict, data, width, height, bits);
  if (rgba == null) return null;

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

Uint8List? _toRgba(CosDocument cos, CosDictionary dict, Uint8List data,
    int width, int height, int bits) {
  final count = width * height;
  final out = Uint8List(count * 4);

  final isMask = cos.resolve(dict['ImageMask']) == const CosBoolean(true);
  final space = _colorSpaceOf(cos, dict);

  if ((space == 'DeviceGray' || isMask) && bits == 1) {
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

int _intOf(CosObject? value, {int fallback = 0}) =>
    value is CosInteger ? value.value : fallback;
