import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:test/test.dart';

/// Ground truth: a 64x24 monochrome image (filled rectangle, vertical
/// bar, diagonal line) encoded by ImageMagick/libtiff, decoded with
/// PDF polarity (/BlackIs1 false: black = 0 bits, so white rows are
/// 0xFF). The same image in all three encodings.
const _expected = [
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 252, 31, 127, 255, 255, 255, 255, 255, 252, 31, 191,
  255, 255, 240, 0, 7, 252, 31, 223, 255, 255, 240, 0, 7, 252, 31, 239, 255,
  255, 240, 0, 7, 252, 31, 255, 255, 255, 240, 0, 7, 252, 31, 255, 255, 255,
  240, 0, 7, 252, 31, 254, 255, 255, 240, 0, 7, 252, 31, 255, 127, 255, 240,
  0, 7, 252, 31, 255, 191, 255, 240, 0, 7, 252, 31, 255, 223, 255, 240, 0,
  7, 252, 31, 255, 239, 255, 255, 255, 255, 252, 31, 255, 247, 255, 255,
  255, 255, 252, 31, 255, 251, 255, 255, 255, 255, 252, 31, 255, 255, 255,
  255, 255, 255, 252, 31, 255, 255, 255, 255, 255, 255, 252, 31, 255, 255,
  191, 255, 255, 255, 252, 31, 255, 255, 223, 255, 255, 255, 252, 31, 255,
  255, 239, 255, 255, 255, 252, 31, 255, 255, 247, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255,
];

const _group4 = [
  200, 25, 156, 93, 148, 12, 216, 49, 178, 139, 251, 40, 71, 143, 254, 72,
  95, 101, 107, 236, 173, 61, 148, 31, 178, 136, 29, 148, 141, 148, 124,
  127, 32, 215, 101, 102, 202, 189, 130, 136, 240, 1, 0, 16,
];

const _group3OneD = [
  0, 1, 217, 168, 0, 1, 217, 168, 0, 1, 3, 60, 65, 0, 1, 3, 62, 64, 192, 1,
  176, 98, 135, 232, 184, 0, 1, 176, 98, 135, 52, 32, 0, 1, 176, 98, 134, 4,
  0, 1, 176, 98, 134, 4, 0, 1, 176, 98, 134, 66, 168, 0, 1, 176, 98, 134,
  26, 212, 0, 1, 176, 98, 135, 162, 208, 0, 1, 176, 98, 135, 170, 12, 0, 1,
  176, 98, 135, 82, 32, 0, 1, 3, 58, 210, 0, 1, 3, 52, 232, 224, 1, 3, 48,
  32, 1, 3, 48, 32, 1, 3, 48, 107, 128, 1, 3, 48, 139, 0, 1, 3, 53, 10, 192,
  1, 3, 53, 106, 0, 1, 217, 168, 0, 1, 217, 168, 0, 1, 217, 168,
];

const _group3TwoD = [
  0, 30, 205, 64, 5, 0, 24, 25, 226, 8, 0, 45, 148, 12, 0, 118, 12, 80, 253,
  23, 0, 23, 178, 132, 0, 14, 193, 138, 24, 16, 0, 190, 0, 59, 6, 40, 100,
  42, 128, 5, 236, 173, 64, 7, 96, 197, 15, 69, 160, 0, 189, 148, 24, 0,
  236, 24, 161, 212, 136, 0, 16, 236, 164, 0, 12, 12, 211, 163, 128, 11, 24,
  0, 192, 204, 8, 0, 89, 6, 160, 3, 3, 48, 139, 0, 5, 178, 172, 0, 96, 102,
  173, 64, 0, 132, 96, 3, 217, 168, 0, 160,
];

CosDictionary _params(int k, {bool blackIs1 = false, bool align = false}) =>
    CosDictionary({
      'K': CosInteger(k),
      'Columns': const CosInteger(64),
      'Rows': const CosInteger(24),
      if (blackIs1) 'BlackIs1': const CosBoolean(true),
      if (align) 'EncodedByteAlign': const CosBoolean(true),
    });

void main() {
  const filter = CcittFaxFilter();

  test('Group 4 decodes a libtiff-encoded image', () {
    final out = filter.decode(Uint8List.fromList(_group4), _params(-1));
    expect(out, _expected);
  });

  test('Group 3 1-D decodes (EOLs with fill bits)', () {
    final out = filter.decode(Uint8List.fromList(_group3OneD), _params(0));
    expect(out, _expected);
  });

  test('Group 3 2-D decodes (per-line mode bits)', () {
    final out = filter.decode(Uint8List.fromList(_group3TwoD), _params(4));
    expect(out, _expected);
  });

  test('/BlackIs1 inverts the output polarity', () {
    final out = filter.decode(
        Uint8List.fromList(_group4), _params(-1, blackIs1: true));
    expect(out, [for (final b in _expected) 255 - b]);
  });

  test('/EncodedByteAlign restarts rows on byte boundaries', () {
    // 12 columns, two 1-D rows of 4 white + 8 black; each row is 10
    // code bits (white 4 = 1011, black 8 = 000101) padded to a byte
    // boundary before the next starts
    final data = Uint8List.fromList([0xB1, 0x40, 0xB1, 0x40]);
    final out = CcittDecoder(
      data: data,
      k: 0,
      columns: 12,
      rows: 2,
      byteAlign: true,
    ).decode();
    expect(out, [0xF0, 0x00, 0xF0, 0x00]);
  });

  test('runs as a stream filter through DecodeParms', () {
    final stream = CosStream(
      CosDictionary({
        'Filter': const CosName('CCITTFaxDecode'),
        'DecodeParms': _params(-1),
        'Length': CosInteger(_group4.length),
      }),
      Uint8List.fromList(_group4),
    );
    expect(decodeStream(stream), _expected);
  });

  test('truncated data still yields the declared rows', () {
    final out = filter.decode(
        Uint8List.sublistView(Uint8List.fromList(_group4), 0, 20),
        _params(-1));
    expect(out, hasLength(24 * 8));
  });
}
