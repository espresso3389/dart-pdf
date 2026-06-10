import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  late CosDocument cos;

  setUp(() => cos = CosDocument.open(buildClassicPdf()));

  CosDictionary exponential({List<double> c0 = const [1, 0, 0]}) =>
      CosDictionary({
        'FunctionType': const CosInteger(2),
        'Domain': CosArray([const CosInteger(0), const CosInteger(1)]),
        'C0': CosArray([for (final v in c0) CosReal(v)]),
        'C1': CosArray([
          const CosInteger(0),
          const CosInteger(0),
          const CosInteger(1),
        ]),
        'N': const CosInteger(1),
      });

  group('PdfFunction', () {
    test('type 2 interpolates exponentially', () {
      final fn = PdfFunction.parse(cos, exponential())!;
      expect(fn.evaluate(0), [1, 0, 0]);
      expect(fn.evaluate(1), [0, 0, 1]);
      expect(fn.evaluate(0.5), [0.5, 0, 0.5]);
    });

    test('type 3 stitches subfunctions', () {
      final fn = PdfFunction.parse(
        cos,
        CosDictionary({
          'FunctionType': const CosInteger(3),
          'Domain': CosArray([const CosInteger(0), const CosInteger(1)]),
          'Functions': CosArray([
            exponential(c0: const [0, 0, 0]),
            exponential(c0: const [1, 1, 1]),
          ]),
          'Bounds': CosArray([const CosReal(0.5)]),
          'Encode': CosArray([
            const CosInteger(0),
            const CosInteger(1),
            const CosInteger(0),
            const CosInteger(1),
          ]),
        }),
      )!;
      expect(fn.evaluate(0.25), [0, 0, 0.5]);
      expect(fn.evaluate(0.75), [0.5, 0.5, 1]);
    });

    test('type 0 interpolates linearly between samples', () {
      final fn = PdfFunction.parse(
        cos,
        CosStream(
          CosDictionary({
            'FunctionType': const CosInteger(0),
            'Domain': CosArray([const CosInteger(0), const CosInteger(1)]),
            'Range': CosArray([const CosInteger(0), const CosInteger(1)]),
            'Size': CosArray([const CosInteger(2)]),
            'BitsPerSample': const CosInteger(8),
          }),
          Uint8List.fromList([0, 255]),
        ),
      )!;
      expect(fn.evaluate(0).single, 0);
      expect(fn.evaluate(1).single, 1);
      expect(fn.evaluate(0.5).single, closeTo(0.5, 1e-9));
      expect(fn.evaluate(0.25).single, closeTo(0.25, 1e-9));
    });

    CosStream calculator(String program, {List<CosObject>? range}) =>
        CosStream(
          CosDictionary({
            'FunctionType': const CosInteger(4),
            'Domain': CosArray([const CosInteger(0), const CosInteger(1)]),
            'Range': CosArray(range ??
                [const CosInteger(0), const CosInteger(1)]),
            'Length': CosInteger(program.length),
          }),
          ascii(program),
        );

    group('type 4 (PostScript calculator)', () {
      test('arithmetic and stack operators', () {
        final fn = PdfFunction.parse(
            cos, calculator('{ dup 0.5 mul exch 2 exp add }'))!;
        // x/2 + x^2
        expect(fn.evaluate(0.5).single, closeTo(0.5, 1e-9));
        expect(fn.evaluate(1).single, 1);
      });

      test('conditionals branch on comparison results', () {
        final fn = PdfFunction.parse(
            cos, calculator('{ 0.5 lt { 0 } { 1 } ifelse }'))!;
        expect(fn.evaluate(0.25).single, 0);
        expect(fn.evaluate(0.75).single, 1);
      });

      test('multiple outputs come off the stack in order', () {
        // tint transform shape: one input to three components
        final fn = PdfFunction.parse(
          cos,
          calculator('{ dup dup 0.5 mul }', range: [
            const CosInteger(0),
            const CosInteger(1),
            const CosInteger(0),
            const CosInteger(1),
            const CosInteger(0),
            const CosInteger(1),
          ]),
        )!;
        expect(fn.evaluate(0.8), [
          closeTo(0.8, 1e-9),
          closeTo(0.8, 1e-9),
          closeTo(0.4, 1e-9),
        ]);
      });

      test('roll, index, and degree trigonometry', () {
        // 1 2 3 with "3 1 roll" becomes 3 1 2; two pops leave the 3
        final fn = PdfFunction.parse(
            cos, calculator('{ pop 1 2 3 3 1 roll pop pop }', range: [
          const CosInteger(0),
          const CosInteger(10),
        ]))!;
        expect(fn.evaluate(0).single, 3);
        final sine =
            PdfFunction.parse(cos, calculator('{ pop 90 sin }'))!;
        expect(sine.evaluate(0).single, closeTo(1, 1e-9));
      });

      test('outputs clamp to /Range', () {
        final fn = PdfFunction.parse(cos, calculator('{ 4 mul }'))!;
        expect(fn.evaluate(0.9).single, 1);
      });

      test('broken programs fall back to the range floor', () {
        final fn =
            PdfFunction.parse(cos, calculator('{ pop frobnicate }'))!;
        expect(fn.evaluate(0.5).single, 0);
      });

      test('comments and nested procedures parse', () {
        final fn = PdfFunction.parse(
            cos,
            calculator(
                '{ % a comment\n true { 0.5 } if }'))!;
        expect(fn.evaluate(0.1).single, 0.5);
      });
    });
  });

  group('PdfShading', () {
    test('axial shading samples into gradient stops', () {
      final shading = PdfShading.parse(
        cos,
        CosDictionary({
          'ShadingType': const CosInteger(2),
          'ColorSpace': const CosName('DeviceRGB'),
          'Coords': CosArray([
            const CosInteger(0),
            const CosInteger(0),
            const CosInteger(100),
            const CosInteger(0),
          ]),
          'Function': exponential(),
        }),
      )!;
      final gradient = shading.toGradient(PdfMatrix.identity)!;
      expect(gradient.isRadial, isFalse);
      expect(gradient.colors.first, const PdfColor(1, 0, 0));
      expect(gradient.colors.last, const PdfColor(0, 0, 1));
      expect(gradient.stops.first, 0);
      expect(gradient.stops.last, 1);
    });

    test('mesh shading types return no gradient', () {
      final shading = PdfShading.parse(
        cos,
        CosDictionary({
          'ShadingType': const CosInteger(4),
          'ColorSpace': const CosName('DeviceRGB'),
        }),
      )!;
      expect(shading.toGradient(PdfMatrix.identity), isNull);
    });
  });
}
