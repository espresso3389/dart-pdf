// Predefined Shift-JIS (90ms-RKSJ) CMap decoding for non-embedded
// Adobe-Japan1 Type0 fonts.
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdf_graphics/src/fonts/cjk_cmap.dart';
import 'package:test/test.dart';

void main() {
  group('ShiftJisCmap', () {
    const cmap = ShiftJisCmap();

    test('handles only RKSJ-family encoding names', () {
      expect(ShiftJisCmap.handles('90ms-RKSJ-H'), isTrue);
      expect(ShiftJisCmap.handles('90pv-RKSJ-V'), isTrue);
      expect(ShiftJisCmap.handles('Ext-RKSJ-H'), isTrue);
      expect(ShiftJisCmap.handles('Identity-H'), isFalse);
      expect(ShiftJisCmap.handles('UniJIS-UCS2-H'), isFalse);
      expect(ShiftJisCmap.handles(null), isFalse);
    });

    test('splits bytes by the Shift-JIS codespace', () {
      // 日本語テスト = 93FA 967B 8CEA 8365 8358 8367 (all two-byte).
      final bytes = Uint8List.fromList(
          [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x83, 0x65, 0x83, 0x58, 0x83, 0x67]);
      expect(cmap.split(bytes),
          [0x93FA, 0x967B, 0x8CEA, 0x8365, 0x8358, 0x8367]);
    });

    test('splits mixed single- and double-byte runs', () {
      // 'A' (0x41) + half-width katakana ｱ (0xB1) + 日 (0x93FA).
      final bytes = Uint8List.fromList([0x41, 0xB1, 0x93, 0xFA]);
      expect(cmap.split(bytes), [0x41, 0xB1, 0x93FA]);
    });

    test('maps two-byte codes to Unicode', () {
      expect(cmap.unicode(0x93FA), '日');
      expect(cmap.unicode(0x967B), '本');
      expect(cmap.unicode(0x8CEA), '語');
      expect(cmap.unicode(0x8365), 'テ');
      expect(cmap.unicode(0x8358), 'ス');
      expect(cmap.unicode(0x8367), 'ト');
    });

    test('maps single-byte ASCII and half-width katakana', () {
      expect(cmap.unicode(0x41), 'A');
      expect(cmap.unicode(0xB1), 'ｱ'); // U+FF71
      expect(cmap.unicode(0xDF), 'ﾟ'); // U+FF9F (last half-width kana)
    });

    test('returns empty for unmapped two-byte codes', () {
      expect(cmap.unicode(0x8540), isEmpty); // a reserved/undefined pair
    });
  });

  test('extracts Japanese from a non-embedded 90ms-RKSJ Type0 font', () {
    final file = File('../../test_corpora/pdfjs/90ms_rksj_h_sample.pdf');
    final doc = PdfDocument.open(file.readAsBytesSync());
    final text = PdfTextExtractor.extract(doc, 0);
    expect(text.text, contains('Hello ASCII'));
    expect(text.text, contains('日本語テスト'));
  });
}
