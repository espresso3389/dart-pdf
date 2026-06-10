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

  testWidgets('masked-out pixels premultiply to transparent black',
      (tester) async {
    await tester.runAsync(() async {
      // a white image whose SMask hides the first pixel: rgba8888 is
      // premultiplied, so (255,255,255,0) would composite as additive
      // white instead of disappearing
      final smask = CosStream(
        CosDictionary({
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(8),
        }),
        Uint8List.fromList([0, 255]),
      );
      final image = CosStream(
        CosDictionary({
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(8),
          'ColorSpace': const CosName('DeviceRGB'),
          'SMask': smask,
        }),
        Uint8List.fromList([255, 255, 255, 255, 255, 255]),
      );
      final images = await decodeImages(cos, [image]);
      final pixels = await pixelsOf(images[image]!);
      expect(pixels.sublist(0, 4), [0, 0, 0, 0]);
      expect(pixels.sublist(4, 8), [255, 255, 255, 255]);
    });
  });

  testWidgets('indexed palettes resolve through an ICCBased base',
      (tester) async {
    await tester.runAsync(() async {
      // a 3-component ICC profile stream standing in for sRGB; the decoder
      // only reads /N
      final profile = CosStream(
          CosDictionary({'N': const CosInteger(3)}), Uint8List(0));
      final image = CosStream(
        CosDictionary({
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(8),
          'ColorSpace': CosArray([
            const CosName('Indexed'),
            CosArray([const CosName('ICCBased'), profile]),
            const CosInteger(1),
            CosString(Uint8List.fromList([255, 0, 0, 0, 255, 0])),
          ]),
        }),
        Uint8List.fromList([0, 1]),
      );
      final images = await decodeImages(cos, [image]);
      final pixels = await pixelsOf(images[image]!);
      expect(pixels.sublist(0, 4), [255, 0, 0, 255]); // red
      expect(pixels.sublist(4, 8), [0, 255, 0, 255]); // green
    });
  });

  testWidgets('indexed CMYK palettes convert to RGB', (tester) async {
    await tester.runAsync(() async {
      final image = CosStream(
        CosDictionary({
          'Width': const CosInteger(2),
          'Height': const CosInteger(1),
          'BitsPerComponent': const CosInteger(8),
          'ColorSpace': CosArray([
            const CosName('Indexed'),
            const CosName('DeviceCMYK'),
            const CosInteger(1),
            // pure cyan, pure black
            CosString(Uint8List.fromList([255, 0, 0, 0, 0, 0, 0, 255])),
          ]),
        }),
        Uint8List.fromList([0, 1]),
      );
      final images = await decodeImages(cos, [image]);
      final pixels = await pixelsOf(images[image]!);
      expect(pixels.sublist(0, 4), [0, 255, 255, 255]); // cyan
      expect(pixels.sublist(4, 8), [0, 0, 0, 255]); // black
    });
  });

  testWidgets('4-bit indexed samples unpack two pixels per byte',
      (tester) async {
    await tester.runAsync(() async {
      final image = CosStream(
        CosDictionary({
          'Width': const CosInteger(3),
          'Height': const CosInteger(2),
          'BitsPerComponent': const CosInteger(4),
          'ColorSpace': CosArray([
            const CosName('Indexed'),
            const CosName('DeviceRGB'),
            const CosInteger(2),
            CosString(
                Uint8List.fromList([255, 0, 0, 0, 255, 0, 0, 0, 255])),
          ]),
        }),
        // rows are byte-aligned: 0,1,2 then 2,1,0
        Uint8List.fromList([0x01, 0x20, 0x21, 0x00]),
      );
      final images = await decodeImages(cos, [image]);
      final pixels = await pixelsOf(images[image]!);
      List<int> at(int x, int y) =>
          pixels.sublist((y * 3 + x) * 4, (y * 3 + x) * 4 + 3);
      expect(at(0, 0), [255, 0, 0]);
      expect(at(1, 0), [0, 255, 0]);
      expect(at(2, 0), [0, 0, 255]);
      expect(at(0, 1), [0, 0, 255]);
      expect(at(1, 1), [0, 255, 0]);
      expect(at(2, 1), [255, 0, 0]);
    });
  });
}
