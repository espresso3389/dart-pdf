import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

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

  group('page lookup with intermediate /Count', () {
    /// Root /Pages with two kids: an inner /Pages node (two leaves, with
    /// [innerCount] declared and [innerKids] as its children) and one
    /// direct leaf with /Rotate 180. The real page order is 4, 5, 6.
    Uint8List buildTree({required int innerCount, String? innerKids}) {
      final objects = <String>[
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 3 '
            '/MediaBox [0 0 612 792] >>',
        '<< /Type /Pages /Parent 2 0 R /Kids [${innerKids ?? '4 0 R 5 0 R'}]'
            ' /Count $innerCount >>',
        '<< /Type /Page /Parent 3 0 R >>',
        '<< /Type /Page /Parent 3 0 R /Rotate 90 >>',
        '<< /Type /Page /Parent 2 0 R /Rotate 180 >>',
      ];
      final buffer = StringBuffer('%PDF-1.4\n');
      final offsets = <int>[];
      for (var i = 0; i < objects.length; i++) {
        offsets.add(buffer.length);
        buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
      }
      final xrefOffset = buffer.length;
      buffer
        ..write('xref\n0 ${objects.length + 1}\n')
        ..write('0000000000 65535 f \n');
      for (final offset in offsets) {
        buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
      }
      buffer
        ..write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n')
        ..write('startxref\n$xrefOffset\n%%EOF\n');
      return ascii(buffer.toString());
    }

    test('a correct /Count skips the subtree without resolving its kids', () {
      // the inner node's kids are dangling references, so reaching page 2
      // can only succeed by trusting /Count and skipping the subtree
      final doc = PdfDocument.open(
          buildTree(innerCount: 2, innerKids: '40 0 R 50 0 R'));
      expect(doc.page(2).rotation, 180);
    });

    test('a lying /Count falls back to walking every leaf', () {
      final doc = PdfDocument.open(buildTree(innerCount: 1));
      expect(doc.page(2).rotation, 180);
      expect(() => doc.page(3), throwsRangeError);
    });

    test('normal lookup still finds pages inside the subtree', () {
      final doc = PdfDocument.open(buildTree(innerCount: 2));
      expect(doc.page(0).rotation, 0);
      expect(doc.page(1).rotation, 90);
      expect(doc.page(2).rotation, 180);
    });
  });
}
