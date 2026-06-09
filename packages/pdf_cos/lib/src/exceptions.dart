/// Error while parsing PDF syntax.
class CosParseException implements Exception {
  CosParseException(this.message, [this.offset]);

  final String message;

  /// Byte offset in the source where the error was detected, if known.
  final int? offset;

  @override
  String toString() => offset == null
      ? 'CosParseException: $message'
      : 'CosParseException at byte $offset: $message';
}

/// A stream uses a /Filter this library cannot decode yet.
class UnsupportedFilterException implements Exception {
  UnsupportedFilterException(this.filterName);

  final String filterName;

  @override
  String toString() => 'UnsupportedFilterException: $filterName';
}
