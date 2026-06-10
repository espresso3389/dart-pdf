import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdf_graphics/src/fonts/cff.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  late CffFont font;

  setUp(() => font = CffFont.parse(buildTestCffFont())!);

  test('parses the CFF structure', () {
    expect(font.numGlyphs, 2);
    expect(font.isCidKeyed, isFalse);
  });

  test('encoding maps character codes to glyphs', () {
    expect(font.gidForCode(65), 1);
    expect(font.gidForCode(66), 0);
  });

  test('charstrings interpret to em-unit outlines', () {
    final square = font.outlineForGlyph(1)!;
    expect(square.segments.first, isA<PdfMoveTo>());
    final move = square.segments.first as PdfMoveTo;
    expect(move.x, closeTo(0, 1e-9));
    expect(move.y, closeTo(0, 1e-9));
    // 800 font units at the default 0.001 matrix = 0.8 em
    final lines = square.segments.whereType<PdfLineTo>().toList();
    expect(lines, hasLength(3));
    expect(lines[0].x, closeTo(0.8, 1e-9));
    expect(lines[1].y, closeTo(0.8, 1e-9));
    expect(square.segments.last, isA<PdfClosePath>());
  });

  test('width comes from the leading charstring operand', () {
    font.outlineForGlyph(1);
    // nominalWidthX 600 + operand 60 = 660 units = 0.66 em
    expect(font.advanceForGlyph(1), closeTo(0.66, 1e-9));
  });

  test('empty glyphs return no outline but a default width', () {
    expect(font.outlineForGlyph(0), isNull);
    // .notdef has no width operand: defaultWidthX 500
    expect(font.advanceForGlyph(0), closeTo(0.5, 1e-9));
  });

  test('garbage input parses to null', () {
    expect(CffFont.parse(ascii('not a font')), isNull);
  });
}
