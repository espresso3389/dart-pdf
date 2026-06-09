import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

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
}
