import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  late CosDocument cos;

  setUp(() => cos = CosDocument.open(buildClassicPdf()));

  test('simple font widths are thousandths of an em', () {
    final font = CosDictionary({
      'Subtype': const CosName('TrueType'),
      'FirstChar': const CosInteger(65),
      'Widths': CosArray([const CosInteger(722)]),
    });
    expect(PdfFontInfo.load(cos, font).widthOf(65), closeTo(0.722, 1e-9));
  });

  test('Type3 widths scale by the FontMatrix, not /1000', () {
    // browser-print PDFs use Type3 fonts with a 1/2048 glyph space
    final font = CosDictionary({
      'Subtype': const CosName('Type3'),
      'FontMatrix': CosArray([
        const CosReal(0.00048828125),
        const CosInteger(0),
        const CosInteger(0),
        const CosReal(-0.00048828125),
        const CosInteger(0),
        const CosInteger(0),
      ]),
      'FirstChar': const CosInteger(72),
      'Widths': CosArray([const CosReal(1578)]),
    });
    final info = PdfFontInfo.load(cos, font);
    expect(info.widthOf(72), closeTo(1578 / 2048, 1e-9));
  });

  test('Type3 with a missing FontMatrix falls back to /1000', () {
    final font = CosDictionary({
      'Subtype': const CosName('Type3'),
      'FirstChar': const CosInteger(65),
      'Widths': CosArray([const CosInteger(500)]),
    });
    expect(PdfFontInfo.load(cos, font).widthOf(65), closeTo(0.5, 1e-9));
  });
}
