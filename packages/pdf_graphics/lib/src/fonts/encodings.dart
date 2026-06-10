/// Glyph-name tables for simple-font encodings (ISO 32000-1 Annex D).
library;

/// WinAnsiEncoding (cp1252) code → glyph name. Codes 32–126 match
/// StandardEncoding's ASCII range, which is what matters for the common
/// /Encoding values; Standard-vs-WinAnsi differences above 127 are accepted
/// as approximation.
String? winAnsiGlyphName(int code) {
  if (code >= 32 && code <= 126) return _ascii[code - 32];
  return _high[code];
}

const _ascii = [
  'space', 'exclam', 'quotedbl', 'numbersign', 'dollar', 'percent',
  'ampersand', 'quotesingle', 'parenleft', 'parenright', 'asterisk', 'plus',
  'comma', 'hyphen', 'period', 'slash', 'zero', 'one', 'two', 'three',
  'four', 'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon',
  'less', 'equal', 'greater', 'question', 'at', 'A', 'B', 'C', 'D', 'E',
  'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S',
  'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft', 'backslash',
  'bracketright', 'asciicircum', 'underscore', 'grave', 'a', 'b', 'c', 'd',
  'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r',
  's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar', 'braceright',
  'asciitilde',
];

const _high = <int, String>{
  0x80: 'Euro', 0x82: 'quotesinglbase', 0x83: 'florin',
  0x84: 'quotedblbase', 0x85: 'ellipsis', 0x86: 'dagger', 0x87: 'daggerdbl',
  0x88: 'circumflex', 0x89: 'perthousand', 0x8A: 'Scaron',
  0x8B: 'guilsinglleft', 0x8C: 'OE', 0x8E: 'Zcaron', 0x91: 'quoteleft',
  0x92: 'quoteright', 0x93: 'quotedblleft', 0x94: 'quotedblright',
  0x95: 'bullet', 0x96: 'endash', 0x97: 'emdash', 0x98: 'tilde',
  0x99: 'trademark', 0x9A: 'scaron', 0x9B: 'guilsinglright', 0x9C: 'oe',
  0x9E: 'zcaron', 0x9F: 'Ydieresis', 0xA0: 'space', 0xA1: 'exclamdown',
  0xA2: 'cent', 0xA3: 'sterling', 0xA4: 'currency', 0xA5: 'yen',
  0xA6: 'brokenbar', 0xA7: 'section', 0xA8: 'dieresis', 0xA9: 'copyright',
  0xAA: 'ordfeminine', 0xAB: 'guillemotleft', 0xAC: 'logicalnot',
  0xAD: 'hyphen', 0xAE: 'registered', 0xAF: 'macron', 0xB0: 'degree',
  0xB1: 'plusminus', 0xB2: 'twosuperior', 0xB3: 'threesuperior',
  0xB4: 'acute', 0xB5: 'mu', 0xB6: 'paragraph', 0xB7: 'periodcentered',
  0xB8: 'cedilla', 0xB9: 'onesuperior', 0xBA: 'ordmasculine',
  0xBB: 'guillemotright', 0xBC: 'onequarter', 0xBD: 'onehalf',
  0xBE: 'threequarters', 0xBF: 'questiondown', 0xC0: 'Agrave',
  0xC1: 'Aacute', 0xC2: 'Acircumflex', 0xC3: 'Atilde', 0xC4: 'Adieresis',
  0xC5: 'Aring', 0xC6: 'AE', 0xC7: 'Ccedilla', 0xC8: 'Egrave',
  0xC9: 'Eacute', 0xCA: 'Ecircumflex', 0xCB: 'Edieresis', 0xCC: 'Igrave',
  0xCD: 'Iacute', 0xCE: 'Icircumflex', 0xCF: 'Idieresis', 0xD0: 'Eth',
  0xD1: 'Ntilde', 0xD2: 'Ograve', 0xD3: 'Oacute', 0xD4: 'Ocircumflex',
  0xD5: 'Otilde', 0xD6: 'Odieresis', 0xD7: 'multiply', 0xD8: 'Oslash',
  0xD9: 'Ugrave', 0xDA: 'Uacute', 0xDB: 'Ucircumflex', 0xDC: 'Udieresis',
  0xDD: 'Yacute', 0xDE: 'Thorn', 0xDF: 'germandbls', 0xE0: 'agrave',
  0xE1: 'aacute', 0xE2: 'acircumflex', 0xE3: 'atilde', 0xE4: 'adieresis',
  0xE5: 'aring', 0xE6: 'ae', 0xE7: 'ccedilla', 0xE8: 'egrave',
  0xE9: 'eacute', 0xEA: 'ecircumflex', 0xEB: 'edieresis', 0xEC: 'igrave',
  0xED: 'iacute', 0xEE: 'icircumflex', 0xEF: 'idieresis', 0xF0: 'eth',
  0xF1: 'ntilde', 0xF2: 'ograve', 0xF3: 'oacute', 0xF4: 'ocircumflex',
  0xF5: 'otilde', 0xF6: 'odieresis', 0xF7: 'divide', 0xF8: 'oslash',
  0xF9: 'ugrave', 0xFA: 'uacute', 0xFB: 'ucircumflex', 0xFC: 'udieresis',
  0xFD: 'yacute', 0xFE: 'thorn', 0xFF: 'ydieresis',
};

/// The first 229 CFF standard strings (SIDs 0–228): .notdef through zcaron.
/// The remaining expert-set strings (through SID 390) are rarely referenced
/// by Differences and resolve to null here.
const cffStandardStrings = [
  '.notdef', 'space', 'exclam', 'quotedbl', 'numbersign', 'dollar',
  'percent', 'ampersand', 'quoteright', ..._asciiTail,
  'exclamdown', 'cent', 'sterling', 'fraction', 'yen', 'florin', 'section',
  'currency', 'quotesingle', 'quotedblleft', 'guillemotleft',
  'guilsinglleft', 'guilsinglright', 'fi', 'fl', 'endash', 'dagger',
  'daggerdbl', 'periodcentered', 'paragraph', 'bullet', 'quotesinglbase',
  'quotedblbase', 'quotedblright', 'guillemotright', 'ellipsis',
  'perthousand', 'questiondown', 'grave', 'acute', 'circumflex', 'tilde',
  'macron', 'breve', 'dotaccent', 'dieresis', 'ring', 'cedilla',
  'hungarumlaut', 'ogonek', 'caron', 'emdash', 'AE', 'ordfeminine',
  'Lslash', 'Oslash', 'OE', 'ordmasculine', 'ae', 'dotlessi', 'lslash',
  'oslash', 'oe', 'germandbls', 'onesuperior', 'logicalnot', 'mu',
  'trademark', 'Eth', 'onehalf', 'plusminus', 'Thorn', 'onequarter',
  'divide', 'brokenbar', 'degree', 'thorn', 'threequarters', 'twosuperior',
  'registered', 'minus', 'eth', 'multiply', 'threesuperior', 'copyright',
  'Aacute', 'Acircumflex', 'Adieresis', 'Agrave', 'Aring', 'Atilde',
  'Ccedilla', 'Eacute', 'Ecircumflex', 'Edieresis', 'Egrave', 'Iacute',
  'Icircumflex', 'Idieresis', 'Igrave', 'Ntilde', 'Oacute', 'Ocircumflex',
  'Odieresis', 'Ograve', 'Otilde', 'Scaron', 'Uacute', 'Ucircumflex',
  'Udieresis', 'Ugrave', 'Yacute', 'Ydieresis', 'Zcaron', 'aacute',
  'acircumflex', 'adieresis', 'agrave', 'aring', 'atilde', 'ccedilla',
  'eacute', 'ecircumflex', 'edieresis', 'egrave', 'iacute', 'icircumflex',
  'idieresis', 'igrave', 'ntilde', 'oacute', 'ocircumflex', 'odieresis',
  'ograve', 'otilde', 'scaron', 'uacute', 'ucircumflex', 'udieresis',
  'ugrave', 'yacute', 'ydieresis', 'zcaron',
];

// ASCII names after quotesingle (SID 9 is parenleft): the standard strings
// use 'quoteright' for 0x27 and 'quoteleft' for 0x60, unlike WinAnsi.
const _asciiTail = [
  'parenleft', 'parenright', 'asterisk', 'plus', 'comma', 'hyphen',
  'period', 'slash', 'zero', 'one', 'two', 'three', 'four', 'five', 'six',
  'seven', 'eight', 'nine', 'colon', 'semicolon', 'less', 'equal',
  'greater', 'question', 'at', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I',
  'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W',
  'X', 'Y', 'Z', 'bracketleft', 'backslash', 'bracketright', 'asciicircum',
  'underscore', 'quoteleft', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i',
  'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w',
  'x', 'y', 'z', 'braceleft', 'bar', 'braceright', 'asciitilde',
];
