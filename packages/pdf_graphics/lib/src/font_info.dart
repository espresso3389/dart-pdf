import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';

import 'fonts/truetype.dart';
import 'path.dart';

/// Metrics, text decoding, and (for embedded TrueType fonts) real glyph
/// outlines for one font dictionary. Fonts without usable embedded outlines
/// fall back to device-side substitution scaled to these widths.
class PdfFontInfo {
  PdfFontInfo._({
    required this.baseFont,
    required this.isCid,
    required Map<int, double> widths,
    required double defaultWidth,
    required Map<int, String> toUnicode,
    TrueTypeFont? trueType,
    Uint8List? cidToGid,
    bool symbolic = false,
  })  : _widths = widths,
        _defaultWidth = defaultWidth,
        _toUnicode = toUnicode,
        _trueType = trueType,
        _cidToGid = cidToGid,
        _symbolic = symbolic;

  final String? baseFont;

  /// True for Type0 composite fonts, which use two-byte codes here.
  /// Assumes an Identity CMap (the overwhelmingly common case); other
  /// predefined CMaps are a TODO.
  final bool isCid;

  final Map<int, double> _widths;
  final double _defaultWidth;
  final Map<int, String> _toUnicode;
  final TrueTypeFont? _trueType;
  final Uint8List? _cidToGid;
  final bool _symbolic;

  /// True when embedded glyph outlines are available.
  bool get hasOutlines => _trueType != null;

  static PdfFontInfo load(CosDocument cos, CosDictionary font) {
    final subtype = font['Subtype'];
    final subtypeName = subtype is CosName ? subtype.value : '';
    final baseFontObj = cos.resolve(font['BaseFont']);
    final baseFont = baseFontObj is CosName ? baseFontObj.value : null;
    final isCid = subtypeName == 'Type0';

    // Widths are in thousandths of an em — except for Type3 fonts, whose
    // glyph space is defined by /FontMatrix (§9.6.5).
    var widthScale = 0.001;
    if (subtypeName == 'Type3') {
      final matrix = cos.resolve(font['FontMatrix']);
      if (matrix is CosArray && matrix.length >= 6) {
        final a = _toNum(cos.resolve(matrix[0]));
        if (a != 0) widthScale = a.abs();
      }
    }

    final widths = <int, double>{};
    var defaultWidth = 0.5;
    final toUnicode = _parseToUnicode(cos, font['ToUnicode']);
    TrueTypeFont? trueType;
    Uint8List? cidToGid;
    var symbolic = false;

    if (isCid) {
      final descendants = cos.resolve(font['DescendantFonts']);
      final descendant = descendants is CosArray && descendants.length > 0
          ? cos.resolve(descendants[0])
          : null;
      if (descendant is CosDictionary) {
        final dw = cos.resolve(descendant['DW']);
        defaultWidth = dw is CosInteger
            ? dw.value / 1000
            : dw is CosReal
                ? dw.value / 1000
                : 1.0;
        _parseCidWidths(cos, cos.resolve(descendant['W']), widths);
        final descriptor = cos.resolve(descendant['FontDescriptor']);
        if (descriptor is CosDictionary) {
          trueType = _loadTrueType(cos, descriptor);
          symbolic = _isSymbolic(cos, descriptor);
        }
        final gidMap = cos.resolve(descendant['CIDToGIDMap']);
        if (gidMap is CosStream) {
          try {
            cidToGid = cos.decodeStreamData(gidMap);
          } on Exception {
            cidToGid = null;
          }
        }
      }
    } else {
      final firstCharObj = cos.resolve(font['FirstChar']);
      final firstChar = firstCharObj is CosInteger ? firstCharObj.value : 0;
      final w = cos.resolve(font['Widths']);
      if (w is CosArray) {
        for (var i = 0; i < w.length; i++) {
          final value = cos.resolve(w[i]);
          widths[firstChar + i] = _toNum(value) * widthScale;
        }
      }
      final descriptor = cos.resolve(font['FontDescriptor']);
      if (descriptor is CosDictionary) {
        final missing = cos.resolve(descriptor['MissingWidth']);
        if (missing is CosInteger) {
          defaultWidth = missing.value * widthScale;
        }
        trueType = _loadTrueType(cos, descriptor);
        symbolic = _isSymbolic(cos, descriptor);
      }
    }

    return PdfFontInfo._(
      baseFont: baseFont,
      isCid: isCid,
      widths: widths,
      defaultWidth: defaultWidth,
      toUnicode: toUnicode,
      trueType: trueType,
      cidToGid: cidToGid,
      symbolic: symbolic,
    );
  }

  static TrueTypeFont? _loadTrueType(
      CosDocument cos, CosDictionary descriptor) {
    // FontFile2 is TrueType; FontFile3 /Subtype /OpenType may carry glyf
    // outlines too (CFF-flavored OpenType parses to null until the CFF
    // engine lands).
    for (final key in const ['FontFile2', 'FontFile3']) {
      final file = cos.resolve(descriptor[key]);
      if (file is! CosStream) continue;
      try {
        final parsed = TrueTypeFont.parse(cos.decodeStreamData(file));
        if (parsed != null) return parsed;
      } on Exception {
        // fall through to substitution
      }
    }
    return null;
  }

  static bool _isSymbolic(CosDocument cos, CosDictionary descriptor) {
    final flags = cos.resolve(descriptor['Flags']);
    return flags is CosInteger && (flags.value & 4) != 0;
  }

  /// Real outline for one character code, in em units, or null.
  PdfPath? outlineFor(int code) {
    final font = _trueType;
    if (font == null) return null;
    return font.outlineForGlyph(_gidFor(code));
  }

  /// Code → glyph id, per §9.6.6.4 (simple fonts) and §9.7.4.2 (CID fonts).
  int _gidFor(int code) {
    final font = _trueType;
    if (font == null) return 0;
    if (isCid) {
      final map = _cidToGid;
      if (map == null) return code; // Identity
      final index = code * 2;
      if (index + 1 >= map.length) return 0;
      return (map[index] << 8) | map[index + 1];
    }
    if (_symbolic || font.hasSymbolCmap) {
      final gid = font.gidForSymbolCode(code);
      if (gid != 0) return gid;
    }
    final unicode = charFor(code);
    if (unicode.isNotEmpty) {
      final gid = font.gidForUnicode(unicode.runes.first);
      if (gid != 0) return gid;
    }
    final mac = font.gidForMacCode(code);
    if (mac != 0) return mac;
    // subset fonts without a cmap index glyphs directly by code
    if (!font.hasCmap && code < font.numGlyphs) return code;
    return 0;
  }

  /// Splits show-text string bytes into character codes.
  List<int> codesOf(Uint8List bytes) {
    if (!isCid) return bytes;
    final codes = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      codes.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return codes;
  }

  /// Glyph advance in em units (1.0 = the font size). Falls back to the
  /// embedded font's hmtx metrics before the default width.
  double widthOf(int code) {
    final declared = _widths[code];
    if (declared != null) return declared;
    final font = _trueType;
    if (font != null) {
      final advance = font.advanceForGlyph(_gidFor(code));
      if (advance != null && advance > 0) return advance;
    }
    return _defaultWidth;
  }

  /// Best-effort Unicode for one character code.
  String charFor(int code) {
    final mapped = _toUnicode[code];
    if (mapped != null) return mapped;
    if (!isCid && code >= 0x20 && code <= 0xFF) {
      return String.fromCharCode(code); // Latin-1 ≈ Standard/WinAnsi enough
    }
    return '';
  }

  static double _toNum(CosObject? value) {
    if (value is CosInteger) return value.value.toDouble();
    if (value is CosReal) return value.value;
    return 0;
  }

  /// /W array: `c [w1 w2 ...]` lists widths from CID c; `c1 c2 w` sets a
  /// range (§9.7.4.3).
  static void _parseCidWidths(
      CosDocument cos, CosObject? w, Map<int, double> out) {
    if (w is! CosArray) return;
    var i = 0;
    while (i < w.length) {
      final first = cos.resolve(w[i]);
      if (first is! CosInteger || i + 1 >= w.length) break;
      final second = cos.resolve(w[i + 1]);
      if (second is CosArray) {
        for (var k = 0; k < second.length; k++) {
          out[first.value + k] = _toNum(cos.resolve(second[k])) / 1000;
        }
        i += 2;
      } else if (second is CosInteger && i + 2 < w.length) {
        final width = _toNum(cos.resolve(w[i + 2])) / 1000;
        for (var cid = first.value; cid <= second.value; cid++) {
          out[cid] = width;
        }
        i += 3;
      } else {
        break;
      }
    }
  }

  /// Minimal ToUnicode CMap reader: bfchar and bfrange sections only, which
  /// covers what real-world writers emit.
  static Map<int, String> _parseToUnicode(CosDocument cos, CosObject? ref) {
    final stream = cos.resolve(ref);
    if (stream is! CosStream) return const {};
    final Uint8List data;
    try {
      data = cos.decodeStreamData(stream);
    } on Exception {
      return const {};
    }
    final map = <int, String>{};
    final parser = CosParser(data);
    try {
      while (true) {
        final t = parser.nextToken();
        if (t.type == CosTokenType.eof) break;
        if (t.isKeyword('beginbfchar')) {
          _parseBfChars(parser, map);
        } else if (t.isKeyword('beginbfrange')) {
          _parseBfRanges(parser, map);
        }
      }
    } on CosParseException {
      // keep whatever was mapped before the malformed section
    }
    return map;
  }

  static void _parseBfChars(CosParser parser, Map<int, String> map) {
    while (true) {
      final src = parser.nextToken();
      if (src.isKeyword('endbfchar') || src.type == CosTokenType.eof) return;
      final dst = parser.nextToken();
      if (src.type == CosTokenType.hexString &&
          dst.type == CosTokenType.hexString) {
        map[_codeOf(src.bytesValue)] = _utf16Be(dst.bytesValue);
      }
    }
  }

  static void _parseBfRanges(CosParser parser, Map<int, String> map) {
    while (true) {
      final lo = parser.nextToken();
      if (lo.isKeyword('endbfrange') || lo.type == CosTokenType.eof) return;
      final hi = parser.nextToken();
      if (lo.type != CosTokenType.hexString ||
          hi.type != CosTokenType.hexString) {
        return;
      }
      final loCode = _codeOf(lo.bytesValue);
      final hiCode = _codeOf(hi.bytesValue);
      final dst = parser.peekToken();
      if (dst.type == CosTokenType.arrayOpen) {
        final list = parser.parseObject() as CosArray;
        for (var k = 0; k < list.length && loCode + k <= hiCode; k++) {
          final item = list[k];
          if (item is CosString) map[loCode + k] = _utf16Be(item.bytes);
        }
      } else if (dst.type == CosTokenType.hexString) {
        parser.nextToken();
        final base = dst.bytesValue;
        for (var code = loCode; code <= hiCode; code++) {
          final unit = _codeOf(base) + (code - loCode);
          map[code] = base.length <= 2
              ? String.fromCharCode(unit)
              : _utf16Be(_withIncrementedTail(base, code - loCode));
        }
      } else {
        return;
      }
    }
  }

  static int _codeOf(Uint8List bytes) {
    var value = 0;
    for (final b in bytes) {
      value = (value << 8) | b;
    }
    return value;
  }

  static Uint8List _withIncrementedTail(Uint8List base, int delta) {
    final out = Uint8List.fromList(base);
    var carry = delta;
    for (var i = out.length - 1; i >= 0 && carry > 0; i--) {
      final sum = out[i] + carry;
      out[i] = sum & 0xFF;
      carry = sum >> 8;
    }
    return out;
  }

  static String _utf16Be(Uint8List bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
}
