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
    // drawn at 72,720 in 24pt with built-in Helvetica AFM advances
    expect(run.bounds.left, 72);
    expect(run.bounds.right,
        closeTo(72 + measureHelvetica('Hello, world!', 24), 1e-6));
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
    // 'world' starts at char 7 of 13; rects interpolate linearly across
    // the run's drawn width
    final width = measureHelvetica('Hello, world!', 24);
    expect(rect.left, closeTo(72 + width * (7 / 13), 1e-6));
    expect(rect.right, closeTo(72 + width * (12 / 13), 1e-6));
  });

  test('search is case-insensitive by default', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final text = PdfTextExtractor.extract(doc, 0);
    expect(text.findAll('HELLO'), hasLength(1));
    expect(text.findAll('HELLO', caseSensitive: true), isEmpty);
  });

  test('positionNear maps page points to character offsets', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final text = PdfTextExtractor.extract(doc, 0);
    // 'Hello, world!' at 72,720 in 24pt; offsets interpolate linearly
    // across the run width
    final perChar = measureHelvetica('Hello, world!', 24) / 13;
    expect(text.positionNear(72, 720), 0);
    expect(text.positionNear(72 + perChar * 7, 720), 7); // before 'w'
    expect(text.positionNear(228, 720), 13); // past the end
    // snaps vertically from outside the bounds
    expect(text.positionNear(72 + perChar * 7, 750), 7);
    // but respects a finite tolerance
    expect(text.positionNear(72, 400, tolerance: 20), -1);
    expect(text.positionNear(400, 400, tolerance: 20), -1);
  });

  test('rectsFor covers a character range', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final text = PdfTextExtractor.extract(doc, 0);
    final rect = text.rectsFor(7, 12).single;
    final perChar = measureHelvetica('Hello, world!', 24) / 13;
    expect(rect.left, closeTo(72 + perChar * 7, 1e-6));
    expect(rect.right, closeTo(72 + perChar * 12, 1e-6));
  });

  test('multi-page documents extract per page', () {
    final doc = PdfDocument.open(buildMultiPagePdf(3));
    expect(PdfTextExtractor.extract(doc, 0).text, 'Page 1');
    expect(PdfTextExtractor.extract(doc, 2).text, 'Page 3');
  });

  test('textIn returns the runs whose center a rectangle covers', () {
    final doc = PdfDocument.open(buildClassicPdf());
    final text = PdfTextExtractor.extract(doc, 0);
    // 'Hello, world!' spans x 72..204, y 714..738 (center ~138, 726)
    expect(text.textIn(const PdfRect(60, 700, 300, 760)), 'Hello, world!');
    expect(text.textIn(const PdfRect(0, 0, 50, 50)), '');
    // covering only the tail of the run misses its center — whole runs
    // are in or out, no partial text
    expect(text.textIn(const PdfRect(200, 700, 300, 760)), '');
  });
}
