import 'dart:typed_data';

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

  test('malformed GBK simple Chinese fonts decode byte pairs', () {
    final font = CosDictionary({
      'Subtype': const CosName('TrueType'),
      'BaseFont': const CosName('ËÎÌå'),
      'Encoding': const CosName('WinAnsiEncoding'),
      'FirstChar': const CosInteger(0),
      'Widths': CosArray([
        for (var i = 0; i < 256; i++) const CosInteger(500),
      ]),
    });

    final info = PdfFontInfo.load(cos, font);
    final codes = info.codesOf(Uint8List.fromList([0xC4, 0xBF, 0x20]));

    expect(codes, [0xC4BF]);
    expect(info.charFor(codes[0]), '目');
    expect(info.widthOf(codes[0]), closeTo(1.0, 1e-9));
  });
}
