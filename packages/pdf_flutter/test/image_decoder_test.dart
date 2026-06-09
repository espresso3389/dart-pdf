import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_flutter/src/image_decoder.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

Future<Uint8List> pixelsOf(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  late CosDocument cos;

  setUp(() => cos = CosDocument.open(buildClassicPdf()));

  testWidgets('stencil masks decode to alpha coverage', (tester) async {
    await tester.runAsync(() async {
      final stencil = CosStream(
        CosDictionary({
          'Subtype': const CosName('Image'),
          'ImageMask': const CosBoolean(true),
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(1),
        }),
        // bits: 0 (paint), 1 (skip)
        Uint8List.fromList([0x40]),
      );
      final images = await decodeImages(cos, [stencil]);
      final pixels = await pixelsOf(images[stencil]!);
      expect(pixels[3], 255); // first pixel painted
      expect(pixels[7], 0); // second pixel transparent
    });
  });

  testWidgets('stencil /Decode [1 0] inverts polarity', (tester) async {
    await tester.runAsync(() async {
      final stencil = CosStream(
        CosDictionary({
          'ImageMask': const CosBoolean(true),
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(1),
          'Decode': CosArray([const CosInteger(1), const CosInteger(0)]),
        }),
        Uint8List.fromList([0x40]),
      );
      final images = await decodeImages(cos, [stencil]);
      final pixels = await pixelsOf(images[stencil]!);
      expect(pixels[3], 0);
      expect(pixels[7], 255);
    });
  });

  testWidgets('SMask samples become the alpha channel', (tester) async {
    await tester.runAsync(() async {
      final smask = CosStream(
        CosDictionary({
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(8),
          'ColorSpace': const CosName('DeviceGray'),
        }),
        Uint8List.fromList([255, 0]),
      );
      final image = CosStream(
        CosDictionary({
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(8),
          'ColorSpace': const CosName('DeviceRGB'),
          'SMask': smask,
        }),
        Uint8List.fromList([255, 0, 0, 0, 255, 0]),
      );
      final images = await decodeImages(cos, [image]);
      final pixels = await pixelsOf(images[image]!);
      expect(pixels.sublist(0, 4), [255, 0, 0, 255]); // opaque red
      expect(pixels[7], 0); // green pixel fully masked out
    });
  });

  testWidgets('SMask resamples when dimensions differ', (tester) async {
    await tester.runAsync(() async {
      final smask = CosStream(
        CosDictionary({
          'Width': const CosInteger(1),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(8),
        }),
        Uint8List.fromList([128]),
      );
      final image = CosStream(
        CosDictionary({
          'Width': const CosInteger(2),
          'Height': const CosInteger(2),
          'BitsPerComponent': const CosInteger(8),
          'ColorSpace': const CosName('DeviceGray'),
          'SMask': smask,
        }),
        Uint8List.fromList([10, 20, 30, 40]),
      );
      final images = await decodeImages(cos, [image]);
      final pixels = await pixelsOf(images[image]!);
      for (var i = 0; i < 4; i++) {
        expect(pixels[i * 4 + 3], 128);
      }
    });
  });
}
