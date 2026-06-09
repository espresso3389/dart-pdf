import 'dart:typed_data';

enum CosTokenType {
  integer,
  real,
  string,
  hexString,
  name,
  arrayOpen,
  arrayClose,
  dictOpen,
  dictClose,
  keyword,
  eof,
}

class CosToken {
  const CosToken(this.type, this.offset, [this.value]);

  final CosTokenType type;

  /// Byte offset where the token starts.
  final int offset;

  /// `int`, `double`, `String` (names and keywords) or `Uint8List` (strings).
  final Object? value;

  int get intValue => value as int;
  double get realValue => value as double;
  String get textValue => value as String;
  Uint8List get bytesValue => value as Uint8List;

  bool isKeyword(String keyword) =>
      type == CosTokenType.keyword && value == keyword;

  @override
  String toString() =>
      'CosToken(${type.name}${value == null ? '' : ' $value'} @$offset)';
}
