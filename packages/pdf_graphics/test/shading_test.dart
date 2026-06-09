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
