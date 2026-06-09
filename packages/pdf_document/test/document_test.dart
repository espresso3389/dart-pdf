import 'package:pdf_document/pdf_document.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  group('classic one-page document', () {
    late PdfDocument doc;

    setUp(() => doc = PdfDocument.open(buildClassicPdf()));

    test('page count', () {
      expect(doc.pageCount, 1);
    });

    test('page attributes', () {
      final page = doc.page(0);
      expect(page.mediaBox, const PdfRect(0, 0, 612, 792));
      expect(page.cropBox, page.mediaBox);
      expect(page.rotation, 0);
      expect(page.resources.containsKey('Font'), isTrue);
    });

    test('content bytes decode', () {
      final text = String.fromCharCodes(doc.page(0).contentBytes());
      expect(text, contains('Hello, world!'));
    });

    test('out-of-range page throws', () {
      expect(() => doc.page(1), throwsRangeError);
      expect(() => doc.page(-1), throwsRangeError);
    });
  });

  group('xref-stream document', () {
    late PdfDocument doc;

    setUp(() => doc = PdfDocument.open(buildXrefStreamPdf()));

    test('page tree resolves out of the object stream', () {
      expect(doc.pageCount, 1);
      expect(doc.page(0).mediaBox, const PdfRect(0, 0, 612, 792));
    });
  });
}
