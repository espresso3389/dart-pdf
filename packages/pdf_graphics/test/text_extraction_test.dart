import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  test('extracts the fixture page text', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final text = PdfTextExtractor.extract(doc, 0);
    expect(text.text, 'Hello, world!');
    expect(text.runs, hasLength(1));
  });

  test('run bounds sit at the drawn position', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final run = PdfTextExtractor.extract(doc, 0).runs.single;
    // drawn at 72,720 in 24pt; 13 glyphs at the 0.5 em default width
    expect(run.bounds.left, 72);
    expect(run.bounds.right, closeTo(72 + 13 * 0.5 * 24, 1e-6));
    expect(run.bounds.bottom, closeTo(720 - 0.25 * 24, 1e-6));
    expect(run.bounds.top, closeTo(720 + 0.75 * 24, 1e-6));
  });

  test('findAll locates substrings with interpolated rects', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final text = PdfTextExtractor.extract(doc, 0);

    final matches = text.findAll('world');
    expect(matches, hasLength(1));
    final match = matches.single;
    expect(text.text.substring(match.start, match.end), 'world');
    final rect = match.rects.single;
    // 'world' starts at char 7 of 13 across a 156pt run starting at x=72
    expect(rect.left, closeTo(72 + 156 * (7 / 13), 1e-6));
    expect(rect.right, closeTo(72 + 156 * (12 / 13), 1e-6));
  });

  test('search is case-insensitive by default', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final text = PdfTextExtractor.extract(doc, 0);
    expect(text.findAll('HELLO'), hasLength(1));
    expect(text.findAll('HELLO', caseSensitive: true), isEmpty);
  });

  test('multi-page documents extract per page', () {
    final doc = PdfDocument.open(buildMultiPagePdf(3));
    expect(PdfTextExtractor.extract(doc, 0).text, 'Page 1');
    expect(PdfTextExtractor.extract(doc, 2).text, 'Page 3');
  });
}
