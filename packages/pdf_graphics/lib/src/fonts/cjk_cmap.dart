import 'dart:convert';
import 'dart:typed_data';

import '_shift_jis_data.dart';

/// Decoder for the predefined Shift-JIS ("90ms-RKSJ") CMap family used by
/// non-embedded Adobe-Japan1 Type0 fonts.
///
/// A full predefined-CMap implementation would map bytes → CID via the Adobe
/// CMap and CID → Unicode via the registry/ordering. For the common
/// non-embedded case the composition collapses to a plain Shift-JIS (CP932) →
/// Unicode decode, which is what we do here: split the bytes per the Shift-JIS
/// codespace and look each two-byte code up in the embedded table. The renderer
/// has no glyph outlines for these fonts anyway, so it substitutes a system CJK
/// font using the Unicode we return — exactly what PDF.js does in Node.
class ShiftJisCmap {
  const ShiftJisCmap();

  static Uint8List? _table;

  /// The packed `(code, unicode)` table, decoded from base64 on first use.
  static Uint8List get _data => _table ??= base64.decode(shiftJisPackedBase64);

  /// True for predefined Shift-JIS CMap names (90ms-RKSJ-H, 90pv-RKSJ-V,
  /// Ext-RKSJ-H, …) — every member carries the `RKSJ` token.
  static bool handles(String? encodingName) =>
      encodingName != null && encodingName.contains('RKSJ');

  /// Splits show-text bytes into character codes per the Shift-JIS codespace:
  /// lead bytes 0x81–0x9F and 0xE0–0xFC consume a trailing byte; everything
  /// else (ASCII, half-width katakana 0xA1–0xDF) is a single byte.
  List<int> split(Uint8List bytes) {
    final codes = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      final lead = (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC);
      if (lead && i + 1 < bytes.length) {
        codes.add((b << 8) | bytes[++i]);
      } else {
        codes.add(b);
      }
    }
    return codes;
  }

  /// Best-effort Unicode for one Shift-JIS code (empty string when unmapped).
  String unicode(int code) {
    if (code <= 0xFF) {
      if (code >= 0xA1 && code <= 0xDF) {
        return String.fromCharCode(0xFF61 + (code - 0xA1)); // half-width kana
      }
      return String.fromCharCode(code); // ASCII / single-byte Latin-1
    }
    final u = _lookup(code);
    return u == null ? '' : String.fromCharCode(u);
  }

  /// Binary search the sorted 4-bytes-per-entry table for [code].
  static int? _lookup(int code) {
    final data = _data;
    var lo = 0;
    var hi = (data.length ~/ 4) - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final off = mid * 4;
      final key = (data[off] << 8) | data[off + 1];
      if (key == code) return (data[off + 2] << 8) | data[off + 3];
      if (key < code) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }
}
