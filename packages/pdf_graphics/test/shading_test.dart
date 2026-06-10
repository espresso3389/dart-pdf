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

  group('mesh shadings', () {
    CosStream meshStream(int type, List<int> bytes,
        {Map<String, CosObject> extra = const {}}) {
      return CosStream(
        CosDictionary({
          'ShadingType': CosInteger(type),
          'ColorSpace': const CosName('DeviceRGB'),
          'BitsPerCoordinate': const CosInteger(8),
          'BitsPerComponent': const CosInteger(8),
          'BitsPerFlag': const CosInteger(8),
          'Decode': CosArray([
            const CosInteger(0), const CosInteger(255), // x
            const CosInteger(0), const CosInteger(255), // y
            const CosInteger(0), const CosInteger(1), // r
            const CosInteger(0), const CosInteger(1), // g
            const CosInteger(0), const CosInteger(1), // b
          ]),
          'Length': CosInteger(bytes.length),
          ...extra,
        }),
        Uint8List.fromList(bytes),
      );
    }

    test('type 4 free-form triangles decode with edge flags', () {
      // triangle (0,0) red, (100,0) green, (0,100) blue, then a strip
      // continuation (flag 1) adding (100,100) white
      final shading = PdfShading.parse(
          cos,
          meshStream(4, [
            0, 0, 0, 255, 0, 0, //
            0, 100, 0, 0, 255, 0,
            0, 0, 100, 0, 0, 255,
            1, 100, 100, 255, 255, 255,
          ]))!;
      final mesh = shading.toMesh(PdfMatrix.identity)!;
      expect(mesh.vertices, hasLength(4));
      expect(mesh.triangles, [0, 1, 2, 1, 2, 3]);
      expect(mesh.vertices[0].color, const PdfColor(1, 0, 0));
      expect(mesh.vertices[3].x, 100);
      expect(mesh.vertices[3].y, 100);
      expect(mesh.vertices[3].color, const PdfColor(1, 1, 1));
    });

    test('type 4 applies the supplied transform', () {
      final shading = PdfShading.parse(
          cos,
          meshStream(4, [
            0, 0, 0, 255, 0, 0, //
            0, 100, 0, 0, 255, 0,
            0, 0, 100, 0, 0, 255,
          ]))!;
      final mesh =
          shading.toMesh(const PdfMatrix(2, 0, 0, 2, 10, 20))!;
      expect(mesh.vertices[1].x, 210);
      expect(mesh.vertices[2].y, 220);
    });

    test('type 5 lattices triangulate between rows', () {
      final shading = PdfShading.parse(
          cos,
          meshStream(5, [
            0, 0, 255, 0, 0, //
            100, 0, 0, 255, 0,
            0, 100, 0, 0, 255,
            100, 100, 255, 255, 255,
          ], extra: {
            'VerticesPerRow': const CosInteger(2),
          }))!;
      final mesh = shading.toMesh(PdfMatrix.identity)!;
      expect(mesh.vertices, hasLength(4));
      expect(mesh.triangles, hasLength(6)); // two triangles
    });

    test('type 4 colors map through /Function', () {
      final shading = PdfShading.parse(
          cos,
          meshStream(4, [
            0, 0, 0, 0, //
            0, 100, 0, 128,
            0, 0, 100, 255,
          ], extra: {
            // t in [0,1] -> (t, 0, 1-t)
            'Decode': CosArray([
              const CosInteger(0), const CosInteger(255),
              const CosInteger(0), const CosInteger(255),
              const CosInteger(0), const CosInteger(1),
            ]),
            'Function': CosStream(
              CosDictionary({
                'FunctionType': const CosInteger(4),
                'Domain': CosArray(
                    [const CosInteger(0), const CosInteger(1)]),
                'Range': CosArray([
                  const CosInteger(0), const CosInteger(1), //
                  const CosInteger(0), const CosInteger(1),
                  const CosInteger(0), const CosInteger(1),
                ]),
              }),
              ascii('{ dup 0 exch 1 exch sub }'),
            ),
          }))!;
      final mesh = shading.toMesh(PdfMatrix.identity)!;
      expect(mesh.vertices[0].color.red, closeTo(0, 1e-6));
      expect(mesh.vertices[0].color.blue, closeTo(1, 1e-6));
      expect(mesh.vertices[2].color.red, closeTo(1, 1e-6));
      expect(mesh.vertices[2].color.blue, closeTo(0, 1e-6));
    });

    test('type 6 Coons patches tessellate with corner colors', () {
      // a flat unit-square-like patch (0,0)-(90,0)-(90,90)-(0,90); all
      // boundary control points sit on the edges
      final shading = PdfShading.parse(
          cos,
          meshStream(6, [
            0, // new patch
            0, 0, 0, 30, 0, 60, 0, 90, // left edge p11..p14 (x,y pairs)
            30, 90, 60, 90, 90, 90, // to p44
            90, 60, 90, 30, 90, 0, // down to p41
            60, 0, 30, 0, // back toward p11
            255, 0, 0, // c1 red
            0, 255, 0, // c2 green
            0, 0, 255, // c3 blue
            255, 255, 255, // c4 white
          ]))!;
      final mesh = shading.toMesh(PdfMatrix.identity)!;
      // 9x9 vertex grid, 8x8 cells, 2 triangles each
      expect(mesh.vertices, hasLength(81));
      expect(mesh.triangles, hasLength(128 * 3));
      expect(mesh.vertices.first.color, const PdfColor(1, 0, 0));
      expect(mesh.vertices.last.color, const PdfColor(0, 0, 1));
      // geometry spans the patch
      final xs = mesh.vertices.map((v) => v.x);
      expect(xs.reduce((a, b) => a < b ? a : b), closeTo(0, 1e-6));
      expect(xs.reduce((a, b) => a > b ? a : b), closeTo(90, 1e-6));
    });

    test('type 6 edge flags share the previous patch edge', () {
      final patch1 = [
        0,
        0, 0, 0, 30, 0, 60, 0, 90, //
        30, 90, 60, 90, 90, 90,
        90, 60, 90, 30, 90, 0,
        60, 0, 30, 0,
        255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255,
      ];
      final patch2 = [
        2, // share edge p44..p41 (the x=90 edge)
        120, 90, 150, 90, 180, 90, // continues to the right
        180, 60, 180, 30, 180, 0,
        150, 0, 120, 0,
        255, 0, 0, // new c3
        0, 255, 0, // new c4
      ];
      final shading =
          PdfShading.parse(cos, meshStream(6, [...patch1, ...patch2]))!;
      final mesh = shading.toMesh(PdfMatrix.identity)!;
      expect(mesh.vertices, hasLength(162)); // two tessellated patches
      final xs = mesh.vertices.map((v) => v.x);
      expect(xs.reduce((a, b) => a > b ? a : b), closeTo(180, 1e-6));
    });

    test('non-mesh types return no mesh', () {
      final shading = PdfShading.parse(
        cos,
        CosDictionary({
          'ShadingType': const CosInteger(2),
          'ColorSpace': const CosName('DeviceRGB'),
        }),
      )!;
      expect(shading.toMesh(PdfMatrix.identity), isNull);
    });
  });
}
