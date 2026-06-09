import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  group('FlateDecode', () {
    test('round-trips zlib data', () {
      final original = ascii('Hello hello hello hello hello');
      final compressed =
          Uint8List.fromList(const ZLibEncoder().encode(original));
      final stream = CosStream(
        CosDictionary({
          'Filter': const CosName('FlateDecode'),
          'Length': CosInteger(compressed.length),
        }),
        compressed,
      );
      expect(decodeStream(stream), original);
    });

    test('applies PNG up-predictor', () {
      // two rows of 4 columns; row 2 uses filter 2 (Up)
      final raw = Uint8List.fromList([
        0, 1, 2, 3, 4, // row 1: None
        2, 1, 1, 1, 1, // row 2: Up
      ]);
      final compressed = Uint8List.fromList(const ZLibEncoder().encode(raw));
      final stream = CosStream(
        CosDictionary({
          'Filter': const CosName('FlateDecode'),
          'DecodeParms': CosDictionary({
            'Predictor': const CosInteger(12),
            'Columns': const CosInteger(4),
          }),
        }),
        compressed,
      );
      expect(decodeStream(stream), [1, 2, 3, 4, 2, 3, 4, 5]);
    });
  });

  test('ASCIIHexDecode', () {
    const filter = AsciiHexFilter();
    expect(filter.decode(ascii('48656C6C6F>'), null),
        ascii('Hello'));
    expect(filter.decode(ascii('90 1F A>'), null), [0x90, 0x1F, 0xA0]);
  });

  group('ASCII85Decode', () {
    const filter = Ascii85Filter();

    test('full group', () {
      expect(filter.decode(ascii('9jqo^~>'), null), ascii('Man '));
    });

    test('partial group', () {
      expect(filter.decode(ascii('9jqo~>'), null), ascii('Man'));
    });

    test('z shorthand', () {
      expect(filter.decode(ascii('z~>'), null), [0, 0, 0, 0]);
    });
  });

  test('filter chains apply in order', () {
    final original = ascii('chained data chained data');
    final compressed = const ZLibEncoder().encode(original);
    final hex = compressed
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final stream = CosStream(
      CosDictionary({
        'Filter': CosArray([
          const CosName('ASCIIHexDecode'),
          const CosName('FlateDecode'),
        ]),
      }),
      ascii('$hex>'),
    );
    expect(decodeStream(stream), original);
  });

  test('unknown filters throw UnsupportedFilterException', () {
    final stream = CosStream(
      CosDictionary({'Filter': const CosName('JBIG2Decode')}),
      Uint8List(0),
    );
    expect(() => decodeStream(stream),
        throwsA(isA<UnsupportedFilterException>()));
  });
}
