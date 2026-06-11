import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';

/// One content-stream instruction: operands followed by an operator.
class ContentOperation {
  ContentOperation(this.operator, this.operands);

  final String operator;
  final List<CosObject> operands;

  @override
  String toString() =>
      operands.isEmpty ? operator : '${operands.join(' ')} $operator';
}

/// Parses a page content stream into a flat list of operations.
///
/// An inline image (`BI ... ID ... EI`) is surfaced as a single `BI`
/// operation whose operands are the image dictionary and the raw image data
/// as a [CosString].
class ContentStreamParser {
  ContentStreamParser._();

  static List<ContentOperation> parse(Uint8List content) {
    final operations = <ContentOperation>[];
    final parser = CosParser(content);
    final operands = <CosObject>[];
    while (true) {
      final t = parser.peekToken();
      if (t.type == CosTokenType.eof) break;
      if (t.type == CosTokenType.arrayOpen) {
        operands.add(_parseLenientArray(parser));
        continue;
      }
      if (t.type != CosTokenType.keyword) {
        operands.add(parser.parseObject());
        continue;
      }
      switch (t.textValue) {
        // true/false/null are operands, not operators
        case 'true' || 'false' || 'null':
          operands.add(parser.parseObject());
        case 'BI':
          operations.add(_parseInlineImage(parser));
          operands.clear();
        default:
          parser.nextToken();
          operations.add(ContentOperation(t.textValue, List.of(operands)));
          operands.clear();
      }
    }
    return operations;
  }

  /// Parses an array operand, dropping stray operators found inside it.
  /// Real-world generators emit junk like `[(a) 0.0 Tc -250.0 (b)] TJ`;
  /// a strict parse would abort the whole page on the `Tc`.
  static CosArray _parseLenientArray(CosParser parser) {
    parser.nextToken(); // [
    final items = <CosObject>[];
    while (true) {
      final t = parser.peekToken();
      switch (t.type) {
        case CosTokenType.arrayClose:
          parser.nextToken();
          return CosArray(items);
        case CosTokenType.eof:
          return CosArray(items); // unterminated — keep what parsed
        case CosTokenType.arrayOpen:
          items.add(_parseLenientArray(parser));
        case CosTokenType.keyword:
          if (t.textValue == 'true' ||
              t.textValue == 'false' ||
              t.textValue == 'null') {
            items.add(parser.parseObject());
          } else {
            parser.nextToken(); // stray operator — drop it
          }
        default:
          items.add(parser.parseObject());
      }
    }
  }

  static ContentOperation _parseInlineImage(CosParser parser) {
    parser.nextToken(); // BI
    final dict = CosDictionary();
    while (true) {
      final t = parser.peekToken();
      if (t.isKeyword('ID')) break;
      if (t.type == CosTokenType.eof) {
        throw CosParseException('unterminated inline image', t.offset);
      }
      if (t.type != CosTokenType.name) {
        throw CosParseException(
            'expected name in inline image dictionary, found $t', t.offset);
      }
      parser.nextToken();
      dict[t.textValue] = parser.parseObject();
    }
    final idToken = parser.nextToken(); // ID

    // Exactly one whitespace byte separates ID from the data (§8.9.7).
    final bytes = parser.bytes;
    var dataStart = idToken.offset + 'ID'.length;
    if (dataStart < bytes.length && CosLexer.isWhitespace(bytes[dataStart])) {
      dataStart++;
    }
    // Scan for an EI delimited by whitespace. This can false-positive on
    // pathological binary data; the robust fix (decode the image and check
    // its expected length) comes with the image pipeline.
    var p = dataStart;
    while (true) {
      if (p + 'EI'.length > bytes.length) {
        throw CosParseException('unterminated inline image data', dataStart);
      }
      if (bytes[p] == 0x45 && bytes[p + 1] == 0x49) {
        final beforeOk = p == dataStart || CosLexer.isWhitespace(bytes[p - 1]);
        final afterPos = p + 'EI'.length;
        final afterOk =
            afterPos >= bytes.length || CosLexer.isWhitespace(bytes[afterPos]);
        if (beforeOk && afterOk) break;
      }
      p++;
    }
    var dataEnd = p;
    if (dataEnd > dataStart && CosLexer.isWhitespace(bytes[dataEnd - 1])) {
      dataEnd--;
    }
    final data = Uint8List.sublistView(bytes, dataStart, dataEnd);
    parser.seek(p + 'EI'.length);
    return ContentOperation('BI', [dict, CosString(data)]);
  }
}
