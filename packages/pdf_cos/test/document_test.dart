import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  group('classic xref table', () {
    late CosDocument doc;

    setUp(() => doc = CosDocument.open(buildClassicPdf()));

    test('reads the header version', () {
      expect(doc.version, '1.4');
    });

    test('parses the trailer and catalog', () {
      expect(doc.trailer['Root'], const CosReference(1, 0));
      expect(doc.catalog.typeName, 'Catalog');
    });

    test('loads objects through the xref', () {
      final page = doc.getObject(3, 0) as CosDictionary;
      expect(page.typeName, 'Page');
      final box = doc.resolve(page['MediaBox']) as CosArray;
      expect(box.items, [
        const CosInteger(0),
        const CosInteger(0),
        const CosInteger(612),
        const CosInteger(792),
      ]);
    });

    test('resolve chases reference chains', () {
      final pages = doc.resolve(doc.catalog['Pages']) as CosDictionary;
      expect(pages.typeName, 'Pages');
    });

    test('decodes an unfiltered content stream', () {
      final content = doc.getObject(4, 0) as CosStream;
      final text = String.fromCharCodes(doc.decodeStreamData(content));
      expect(text, contains('Hello, world!'));
    });

    test('free and absent objects resolve to null', () {
      expect(doc.getObject(0, 65535), CosNull.instance);
      expect(doc.getObject(99, 0), CosNull.instance);
    });
  });

  group('xref stream + object stream', () {
    late CosDocument doc;

    setUp(() => doc = CosDocument.open(buildXrefStreamPdf()));

    test('parses the cross-reference stream', () {
      expect(doc.trailer['Root'], const CosReference(1, 0));
      expect(doc.version, '1.5');
    });

    test('loads objects out of the object stream', () {
      expect(doc.catalog.typeName, 'Catalog');
      final pages = doc.resolve(doc.catalog['Pages']) as CosDictionary;
      expect(pages.typeName, 'Pages');
      final page = doc.resolve((pages['Kids'] as CosArray)[0]) as CosDictionary;
      expect(page.typeName, 'Page');
      expect((doc.resolve(page['MediaBox']) as CosArray).length, 4);
    });
  });

  test('junk before the header shifts offsets', () {
    final junk = ascii('GARBAGE BYTES ');
    final pdf = buildClassicPdf();
    final shifted = (BytesBuilder()..add(junk)..add(pdf)).takeBytes();
    final doc = CosDocument.open(shifted);
    expect(doc.catalog.typeName, 'Catalog');
  });

  test('rejects non-PDF data', () {
    expect(() => CosDocument.open(ascii('not a pdf at all')),
        throwsA(isA<CosParseException>()));
  });

  group('xref recovery', () {
    /// Replaces every occurrence of [needle] in [bytes] with garbage of the
    /// same length, so offsets stay valid.
    Uint8List smash(Uint8List bytes, String needle) {
      final text = String.fromCharCodes(bytes);
      final replaced = text.replaceAll(needle, '#' * needle.length);
      expect(replaced, isNot(text), reason: 'needle "$needle" not found');
      return ascii(replaced);
    }

    test('recovers a classic file with a smashed startxref', () {
      final doc = CosDocument.open(smash(buildClassicPdf(), 'startxref'));
      expect(doc.catalog.typeName, 'Catalog');
      final pages = doc.resolve(doc.catalog['Pages']) as CosDictionary;
      expect(pages.typeName, 'Pages');
    });

    test('recovers a classic file whose xref table is corrupt', () {
      final doc = CosDocument.open(smash(buildClassicPdf(), 'xref\n0 6'));
      expect(doc.catalog.typeName, 'Catalog');
    });

    test('finds the catalog by type when the trailer is gone too', () {
      var bytes = smash(buildClassicPdf(), 'startxref');
      bytes = smash(bytes, 'trailer');
      final doc = CosDocument.open(bytes);
      expect(doc.trailer['Root'], const CosReference(1, 0));
      expect(doc.catalog.typeName, 'Catalog');
    });

    test('recovers compressed objects behind a broken xref stream', () {
      final doc = CosDocument.open(smash(buildXrefStreamPdf(), 'startxref'));
      // /Root comes from the xref stream's dictionary; the catalog lives
      // inside the object stream and resolves through the recovered index
      expect(doc.trailer['Root'], const CosReference(1, 0));
      expect(doc.catalog.typeName, 'Catalog');
      final pages = doc.resolve(doc.catalog['Pages']) as CosDictionary;
      expect(pages.typeName, 'Pages');
    });

    test('the last definition of an object number wins', () {
      final updated = (BytesBuilder()
            ..add(smash(buildClassicPdf(), 'startxref'))
            ..add(ascii('5 0 obj\n<< /Type /Font /Subtype /Type1 '
                '/BaseFont /Courier >>\nendobj\n')))
          .takeBytes();
      final doc = CosDocument.open(updated);
      final font = doc.getObject(5, 0) as CosDictionary;
      expect((font['BaseFont'] as CosName).value, 'Courier');
    });

    test('object headers inside string content do not derail recovery', () {
      // "1 0 obj" appearing inside a content stream must not shadow the
      // real object 1 that appears later
      const decoy = 'BT (see 1 0 obj here) Tj ET';
      final body = StringBuffer('%PDF-1.4\n')
        ..write('2 0 obj\n<< /Length ${decoy.length} >>\nstream\n'
            '$decoy\nendstream\nendobj\n')
        ..write('1 0 obj\n<< /Type /Catalog /Pages 3 0 R >>\nendobj\n')
        ..write('3 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n');
      final doc = CosDocument.open(ascii(body.toString()));
      expect(doc.catalog.typeName, 'Catalog');
    });
  });
}
