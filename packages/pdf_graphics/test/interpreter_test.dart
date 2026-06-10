import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

class RecordingDevice implements PdfDevice {
  final calls = <String>[];
  final fills = <(PdfPath, PdfColor, PdfFillRule, double)>[];
  final strokes = <(PdfPath, PdfColor, PdfStroke, double)>[];
  final clips = <(PdfPath, PdfFillRule)>[];
  final texts = <PdfTextRun>[];
  final images = <PdfImageRequest>[];

  @override
  void save() => calls.add('save');

  @override
  void restore() => calls.add('restore');

  final gradients = <(PdfPath, PdfGradient)>[];

  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha) {
    calls.add('fill');
    fills.add((path, color, rule, alpha));
  }

  @override
  void fillPathGradient(
      PdfPath path, PdfFillRule rule, PdfGradient gradient, double alpha) {
    calls.add('gradient');
    gradients.add((path, gradient));
  }

  @override
  void strokePath(
      PdfPath path, PdfColor color, PdfStroke stroke, double alpha) {
    calls.add('stroke');
    strokes.add((path, color, stroke, alpha));
  }

  @override
  void clipPath(PdfPath path, PdfFillRule rule) {
    calls.add('clip');
    clips.add((path, rule));
  }

  @override
  void drawText(PdfTextRun run) {
    calls.add('text');
    texts.add(run);
  }

  @override
  void drawImage(PdfImageRequest request) {
    calls.add('image');
    images.add(request);
  }

  final blendModes = <PdfBlendMode>[];
  final softMaskEnds = <(bool, void Function())>[];

  @override
  void setBlendMode(PdfBlendMode mode) {
    calls.add('blend:${mode.name}');
    blendModes.add(mode);
  }

  @override
  void beginSoftMasked() => calls.add('beginSoftMasked');

  @override
  void endSoftMasked(
      {required bool luminosity,
      required PdfRect backdrop,
      required void Function() drawMask}) {
    calls.add('endSoftMasked');
    softMaskEnds.add((luminosity, drawMask));
  }
}

RecordingDevice interpret(String content) {
  final doc = CosDocument.open(buildClassicPdf());
  final device = RecordingDevice();
  PdfInterpreter(cos: doc, device: device).run(
    ContentStreamParser.parse(Uint8List.fromList(content.codeUnits)),
    CosDictionary(),
  );
  return device;
}

void main() {
  test('fills a rectangle transformed by cm', () {
    final device =
        interpret('q 2 0 0 2 10 10 cm 0 0 1 rg 5 5 20 30 re f Q');
    final (path, color, rule, alpha) = device.fills.single;
    expect(color, const PdfColor(0, 0, 1));
    expect(rule, PdfFillRule.nonzero);
    expect(alpha, 1);
    final move = path.segments.first as PdfMoveTo;
    expect(move.x, 20); // 2*5 + 10
    expect(move.y, 20);
    final corner = path.segments[2] as PdfLineTo;
    expect(corner.x, 60); // 2*(5+20) + 10
    expect(corner.y, 80); // 2*(5+30) + 10
  });

  test('stroke width scales with the CTM', () {
    final device = interpret('4 w 2 0 0 2 0 0 cm 0 0 10 10 re S');
    expect(device.strokes.single.$3.width, 8);
  });

  test('q/Q restores color state', () {
    final device = interpret('q 1 0 0 rg 0 0 1 1 re f Q 0 0 2 2 re f');
    expect(device.fills[0].$2, const PdfColor(1, 0, 0));
    expect(device.fills[1].$2, PdfColor.black);
  });

  test('clip applies after painting, with the same path', () {
    final device = interpret('0 0 5 5 re W n 0 0 10 10 re f');
    expect(device.calls, ['clip', 'fill']);
    expect(device.clips.single.$2, PdfFillRule.nonzero);
  });

  test('CMYK and gray color operators convert to RGB', () {
    final device = interpret('0 0 0 1 k 0 0 1 1 re f 0.5 g 0 0 1 1 re f');
    expect(device.fills[0].$2, PdfColor.black);
    expect(device.fills[1].$2, const PdfColor.gray(0.5));
  });

  test('ExtGState alpha applies to fills', () {
    final doc = CosDocument.open(buildClassicPdf());
    final device = RecordingDevice();
    final resources = CosDictionary({
      'ExtGState': CosDictionary({
        'GS1': CosDictionary({'ca': const CosReal(0.25)}),
      }),
    });
    PdfInterpreter(cos: doc, device: device).run(
      ContentStreamParser.parse(
          Uint8List.fromList('/GS1 gs 0 0 1 1 re f'.codeUnits)),
      resources,
    );
    expect(device.fills.single.$4, 0.25);
  });

  group('text', () {
    test('renders the fixture page text with correct placement', () {
      final doc = PdfDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      PdfInterpreter(cos: doc.cos, device: device).drawPage(doc.page(0));

      final run = device.texts.single;
      expect(run.text, 'Hello, world!');
      expect(run.fontName, 'Helvetica');
      expect(run.transform.e, 72); // Td x
      expect(run.transform.f, 720); // Td y
      expect(run.transform.a, 24); // font size on the x axis
      expect(run.transform.d, 24);
      // 13 chars at the 0.5 em default width
      expect(run.width, closeTo(6.5, 1e-9));
    });

    test('TJ adjustments shift subsequent runs', () {
      final doc = PdfDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      final page = doc.page(0);
      PdfInterpreter(cos: doc.cos, device: device).run(
        ContentStreamParser.parse(Uint8List.fromList(
            'BT /F1 10 Tf [(A) -500 (B)] TJ ET'.codeUnits)),
        page.resources,
      );
      expect(device.texts, hasLength(2));
      expect(device.texts[0].transform.e, 0);
      // A advances 0.5 em * 10 = 5; adjustment -500/1000 * 10 = 5 more
      expect(device.texts[1].transform.e, 10);
    });

    test('invisible text (Tr 3) advances but does not draw', () {
      final doc = PdfDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      final page = doc.page(0);
      PdfInterpreter(cos: doc.cos, device: device).run(
        ContentStreamParser.parse(Uint8List.fromList(
            'BT /F1 10 Tf 3 Tr (ghost) Tj 0 Tr (real) Tj ET'.codeUnits)),
        page.resources,
      );
      final run = device.texts.single;
      expect(run.text, 'real');
      expect(run.transform.e, 25); // advanced past the 5 ghost glyphs
    });
  });

  group('patterns', () {
    CosDictionary shadingPatternResources() => CosDictionary({
          'Pattern': CosDictionary({
            'P0': CosDictionary({
              'PatternType': const CosInteger(2),
              'Shading': CosDictionary({
                'ShadingType': const CosInteger(2),
                'ColorSpace': const CosName('DeviceRGB'),
                'Coords': CosArray([
                  const CosInteger(0),
                  const CosInteger(0),
                  const CosInteger(10),
                  const CosInteger(0),
                ]),
                'Function': CosDictionary({
                  'FunctionType': const CosInteger(2),
                  'C0': CosArray([
                    const CosInteger(1),
                    const CosInteger(0),
                    const CosInteger(0),
                  ]),
                  'C1': CosArray([
                    const CosInteger(0),
                    const CosInteger(0),
                    const CosInteger(1),
                  ]),
                  'N': const CosInteger(1),
                }),
              }),
            }),
          }),
        });

    test('shading pattern fills become gradients, not solid color', () {
      final doc = CosDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      PdfInterpreter(cos: doc, device: device).run(
        ContentStreamParser.parse(Uint8List.fromList(
            '0 0 0 rg /Pattern cs /P0 scn 0 0 10 10 re f'.codeUnits)),
        shadingPatternResources(),
      );
      // regression: this used to paint solid black (the last set color)
      expect(device.fills, isEmpty);
      expect(device.gradients, hasLength(1));
      final gradient = device.gradients.single.$2;
      expect(gradient.colors.first, const PdfColor(1, 0, 0));
    });

    test('tiling patterns run their cell content per tile, clipped', () {
      final doc = CosDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      const cell = '1 0 0 rg 0 0 1 1 re f';
      final resources = CosDictionary({
        'Pattern': CosDictionary({
          'P1': CosStream(
            CosDictionary({
              'PatternType': const CosInteger(1),
              'PaintType': const CosInteger(1),
              'BBox': CosArray([
                const CosInteger(0),
                const CosInteger(0),
                const CosInteger(4),
                const CosInteger(4),
              ]),
              'XStep': const CosInteger(4),
              'YStep': const CosInteger(4),
              'Length': CosInteger(cell.length),
            }),
            Uint8List.fromList(cell.codeUnits),
          ),
        }),
      });
      PdfInterpreter(cos: doc, device: device).run(
        ContentStreamParser.parse(Uint8List.fromList(
            '/Pattern cs /P1 scn 0 0 8 8 re f'.codeUnits)),
        resources,
      );
      expect(device.clips, isNotEmpty);
      // 8x8 area on a 4pt grid: at least 4 cells painted in the cell color
      expect(device.fills.length, greaterThanOrEqualTo(4));
      expect(device.fills.first.$2, const PdfColor(1, 0, 0));
    });

    test('sh paints a gradient across the page area', () {
      final doc = CosDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      final pattern = (shadingPatternResources()['Pattern']
          as CosDictionary)['P0'] as CosDictionary;
      final resources = CosDictionary({
        'Shading': CosDictionary({'S0': pattern['Shading']!}),
      });
      PdfInterpreter(cos: doc, device: device).run(
        ContentStreamParser.parse(Uint8List.fromList('/S0 sh'.codeUnits)),
        resources,
      );
      expect(device.gradients, hasLength(1));
    });
  });

  group('soft masks and blend modes', () {
    CosDictionary maskResources({String type = 'Luminosity'}) {
      const maskContent = '1 g 0 0 50 100 re f';
      return CosDictionary({
        'ExtGState': CosDictionary({
          'GS1': CosDictionary({
            'SMask': CosDictionary({
              'Type': const CosName('Mask'),
              'S': CosName(type),
              'G': CosStream(
                CosDictionary({
                  'Subtype': const CosName('Form'),
                  'BBox': CosArray([
                    const CosInteger(0),
                    const CosInteger(0),
                    const CosInteger(100),
                    const CosInteger(100),
                  ]),
                  'Length': CosInteger(maskContent.length),
                }),
                Uint8List.fromList(maskContent.codeUnits),
              ),
            }),
          }),
        }),
      });
    }

    test('q /gs ... Q wraps content in a masked group', () {
      final doc = CosDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      PdfInterpreter(cos: doc, device: device).run(
        ContentStreamParser.parse(Uint8List.fromList(
            'q /GS1 gs 0 0 100 100 re f Q 0 0 1 1 re f'.codeUnits)),
        maskResources(),
      );
      expect(
        device.calls.where((c) => c.contains('SoftMasked')),
        ['beginSoftMasked', 'endSoftMasked'],
      );
      // begin before the masked fill, end before the unmasked one
      expect(device.calls.indexOf('beginSoftMasked'),
          lessThan(device.calls.indexOf('fill')));
      final (luminosity, drawMask) = device.softMaskEnds.single;
      expect(luminosity, isTrue);
      // the mask painter emits the mask group's content
      final fillsBefore = device.fills.length;
      drawMask();
      expect(device.fills.length, greaterThan(fillsBefore));
    });

    test('alpha masks report luminosity=false', () {
      final doc = CosDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      PdfInterpreter(cos: doc, device: device).run(
        ContentStreamParser.parse(
            Uint8List.fromList('q /GS1 gs 0 0 9 9 re f Q'.codeUnits)),
        maskResources(type: 'Alpha'),
      );
      expect(device.softMaskEnds.single.$1, isFalse);
    });

    test('blend modes reach the device and restore on Q', () {
      final doc = CosDocument.open(buildClassicPdf());
      final device = RecordingDevice();
      final resources = CosDictionary({
        'ExtGState': CosDictionary({
          'GS1': CosDictionary({'BM': const CosName('Multiply')}),
        }),
      });
      PdfInterpreter(cos: doc, device: device).run(
        ContentStreamParser.parse(Uint8List.fromList(
            'q /GS1 gs 0 0 9 9 re f Q 0 0 9 9 re f'.codeUnits)),
        resources,
      );
      expect(device.blendModes,
          [PdfBlendMode.multiply, PdfBlendMode.normal]);
    });
  });

  test('image XObjects reach the device with the CTM', () {
    final doc = CosDocument.open(buildClassicPdf());
    final device = RecordingDevice();
    final image = CosStream(
      CosDictionary({
        'Subtype': const CosName('Image'),
        'Width': const CosInteger(1),
        'Height': const CosInteger(1),
      }),
      Uint8List.fromList([0]),
    );
    final resources = CosDictionary({
      'XObject': CosDictionary({'Im0': image}),
    });
    PdfInterpreter(cos: doc, device: device).run(
      ContentStreamParser.parse(
          Uint8List.fromList('q 100 0 0 50 20 30 cm /Im0 Do Q'.codeUnits)),
      resources,
    );
    final request = device.images.single;
    expect(request.stream, same(image));
    expect(request.transform.a, 100);
    expect(request.transform.d, 50);
    expect(request.transform.e, 20);
    expect(request.transform.f, 30);
  });

  test('form XObjects run with their matrix and clipped bbox', () {
    final doc = CosDocument.open(buildClassicPdf());
    final device = RecordingDevice();
    final form = CosStream(
      CosDictionary({
        'Subtype': const CosName('Form'),
        'BBox': CosArray([
          const CosInteger(0),
          const CosInteger(0),
          const CosInteger(10),
          const CosInteger(10),
        ]),
        'Matrix': CosArray([
          const CosInteger(2),
          const CosInteger(0),
          const CosInteger(0),
          const CosInteger(2),
          const CosInteger(0),
          const CosInteger(0),
        ]),
        'Length': CosInteger('0 0 4 4 re f'.length),
      }),
      Uint8List.fromList('0 0 4 4 re f'.codeUnits),
    );
    final resources = CosDictionary({
      'XObject': CosDictionary({'Fm0': form}),
    });
    PdfInterpreter(cos: doc, device: device).run(
      ContentStreamParser.parse(
          Uint8List.fromList('q 1 0 0 1 100 0 cm /Fm0 Do Q'.codeUnits)),
      resources,
    );
    // bbox clip arrives, then the inner fill, doubly transformed
    expect(device.calls, contains('clip'));
    final fill = device.fills.single;
    final corner = fill.$1.segments[2] as PdfLineTo;
    expect(corner.x, 108); // 2*4 + 100
    expect(corner.y, 8);
  });

  group('annotation appearances', () {
    // page-space bounding box of a recorded fill
    (double, double, double, double) boundsOf(PdfPath path) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
      for (final segment in path.segments) {
        if (segment case PdfMoveTo(:final x, :final y) ||
            PdfLineTo(:final x, :final y)) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
      return (minX, minY, maxX, maxY);
    }

    RecordingDevice drawAnnotations() {
      final doc = PdfDocument.open(buildAppearanceAnnotationsPdf());
      final device = RecordingDevice();
      PdfInterpreter(cos: doc.cos, device: device)
        ..drawPage(doc.page(0))
        ..drawAnnotations(doc.page(0));
      return device;
    }

    test('appearances draw after content; hidden and Popup are skipped', () {
      final device = drawAnnotations();
      // blue page content + green square + red stamp + gray checkbox;
      // the magenta hidden and yellow popup appearances never paint
      expect(device.fills.map((f) => f.$2), [
        const PdfColor(0, 0, 1),
        const PdfColor(0, 1, 0),
        const PdfColor(1, 0, 0),
        const PdfColor.gray(0.5),
      ]);
    });

    test('BBox is scaled onto the annotation Rect', () {
      final device = drawAnnotations();
      final green =
          device.fills.firstWhere((f) => f.$2 == const PdfColor(0, 1, 0));
      expect(boundsOf(green.$1), (100, 100, 200, 150));
    });

    test('appearance /Matrix rotates, then the result maps onto Rect', () {
      final device = drawAnnotations();
      final red =
          device.fills.firstWhere((f) => f.$2 == const PdfColor(1, 0, 0));
      expect(boundsOf(red.$1), (300, 100, 350, 200));
    });

    test('/AS selects the appearance state', () {
      final device = drawAnnotations();
      final gray =
          device.fills.firstWhere((f) => f.$2 == const PdfColor.gray(0.5));
      expect(boundsOf(gray.$1), (400, 100, 420, 120));
    });

    test('each appearance clips to its BBox', () {
      final doc = PdfDocument.open(buildAppearanceAnnotationsPdf());
      final device = RecordingDevice();
      PdfInterpreter(cos: doc.cos, device: device)
          .drawAnnotations(doc.page(0));
      // three drawn appearances, one BBox clip each
      expect(device.clips, hasLength(3));
      expect(boundsOf(device.clips.first.$1), (100, 100, 200, 150));
    });
  });
}
