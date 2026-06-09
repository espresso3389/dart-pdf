import 'dart:typed_data';

import 'exceptions.dart';
import 'filters/filters.dart';
import 'lexer.dart';
import 'objects.dart';
import 'parser.dart';
import 'token.dart';
import 'xref.dart';

/// A parsed PDF file at the COS level: header, cross-reference machinery, and
/// on-demand object loading. Page-level semantics live in `pdf_document`.
class CosDocument {
  CosDocument._(
      this.bytes, this._offsetShift, this._xref, this.trailer, this.startXref);

  final Uint8List bytes;

  /// Offset of the `%PDF-` header. Some files carry junk before the header;
  /// xref offsets are then relative to the header, not the file start.
  final int _offsetShift;

  final Map<int, CosXrefEntry> _xref;
  final CosDictionary trailer;

  /// The newest cross-reference section's offset, as declared after the
  /// `startxref` keyword. An incremental update points /Prev here.
  final int startXref;

  final Map<CosReference, CosObject> _cache = {};
  final Map<int, _ObjectStream> _objectStreams = {};

  static CosDocument open(Uint8List bytes) {
    final shift = _findHeader(bytes);
    final startXref = _findStartXref(bytes);
    final entries = <int, CosXrefEntry>{};
    CosDictionary trailer = CosDictionary();
    var isNewest = true;

    // Walk the xref chain newest-to-oldest; the first entry seen for an
    // object number wins. Hybrid files queue /XRefStm before /Prev.
    final pending = <int>[startXref + shift];
    final visited = <int>{};
    while (pending.isNotEmpty) {
      final offset = pending.removeAt(0);
      if (!visited.add(offset)) continue;
      final section = _parseXrefSection(bytes, offset);
      for (final entry in section.entries.entries) {
        entries.putIfAbsent(entry.key, () => entry.value);
      }
      if (isNewest) {
        trailer = section.trailer;
        isNewest = false;
      }
      final hybrid = section.trailer['XRefStm'];
      if (hybrid is CosInteger) pending.add(hybrid.value + shift);
      final prev = section.trailer['Prev'];
      if (prev is CosInteger) pending.add(prev.value + shift);
    }
    return CosDocument._(bytes, shift, entries, trailer, startXref);
  }

  /// The version from the file header, e.g. `1.7`. The catalog's /Version
  /// entry, when present and newer, overrides this (not yet considered).
  String get version {
    var p = _offsetShift + '%PDF-'.length;
    final sb = StringBuffer();
    while (p < bytes.length && !CosLexer.isWhitespace(bytes[p])) {
      sb.writeCharCode(bytes[p++]);
    }
    return sb.toString();
  }

  CosDictionary get catalog {
    final root = resolve(trailer['Root']);
    if (root is! CosDictionary) {
      throw CosParseException('document has no /Root catalog');
    }
    return root;
  }

  /// Object numbers known to the cross-reference machinery.
  Iterable<int> get objectNumbers => _xref.keys;

  /// Offset of the `%PDF-` header; xref offsets are relative to it.
  int get headerOffset => _offsetShift;

  CosXrefEntry? xrefEntry(int objectNumber) => _xref[objectNumber];

  /// The trailer's declared /Size (one past the highest object number).
  int get declaredSize {
    final size = resolve(trailer['Size']);
    return size is CosInteger ? size.value : 0;
  }

  /// Finds the reference under which [object] was loaded, or null if it is
  /// not an already-loaded indirect object. Identity-based; used by editing
  /// code to map a mutated object back to its number.
  CosReference? referenceTo(CosObject object) {
    for (final entry in _cache.entries) {
      if (identical(entry.value, object)) return entry.key;
    }
    return null;
  }

  /// Loads an object by number, parsing it on first access.
  CosObject getObject(int objectNumber, int generation) {
    final ref = CosReference(objectNumber, generation);
    final cached = _cache[ref];
    if (cached != null) return cached;

    final entry = _xref[objectNumber];
    if (entry == null) return CosNull.instance;

    final CosObject result;
    switch (entry.type) {
      case CosXrefEntryType.free:
        result = CosNull.instance;
      case CosXrefEntryType.inUse:
        final parser = CosParser(bytes,
            offset: entry.offset + _offsetShift, resolver: _resolveRef);
        final indirect = parser.parseIndirectObject();
        if (indirect.objectNumber != objectNumber) {
          throw CosParseException(
              'cross-reference points at object ${indirect.objectNumber}, '
              'expected $objectNumber',
              entry.offset);
        }
        result = indirect.object;
      case CosXrefEntryType.compressed:
        result = _objectStream(entry.streamObjectNumber)
            .objectByNumber(objectNumber, entry.indexInStream);
    }
    _cache[ref] = result;
    return result;
  }

  /// Follows references until reaching a direct object. Null input and
  /// dangling references resolve to [CosNull.instance].
  CosObject resolve(CosObject? object) {
    var current = object ?? CosNull.instance;
    var guard = 0;
    while (current is CosReference) {
      if (guard++ > 1000) throw CosParseException('reference cycle');
      current = getObject(current.objectNumber, current.generation);
    }
    return current;
  }

  /// Decodes a stream's payload, resolving indirect /Length and /Filter
  /// entries against this document.
  Uint8List decodeStreamData(CosStream stream) =>
      decodeStream(stream, resolve: _resolveRef);

  CosObject _resolveRef(CosReference ref) =>
      getObject(ref.objectNumber, ref.generation);

  _ObjectStream _objectStream(int streamObjectNumber) {
    return _objectStreams.putIfAbsent(streamObjectNumber, () {
      final object = getObject(streamObjectNumber, 0);
      if (object is! CosStream) {
        throw CosParseException(
            'object stream $streamObjectNumber is not a stream');
      }
      final data = decodeStreamData(object);
      final count = resolve(object.dictionary['N']);
      final first = resolve(object.dictionary['First']);
      if (count is! CosInteger || first is! CosInteger) {
        throw CosParseException(
            'object stream $streamObjectNumber has invalid /N or /First');
      }
      return _ObjectStream(data, count.value, first.value);
    });
  }

  static int _findHeader(Uint8List bytes) {
    final limit = bytes.length < 1024 ? bytes.length : 1024;
    final index = _indexOf(bytes, '%PDF-', 0, limit);
    if (index < 0) {
      throw CosParseException('not a PDF: missing %PDF- header');
    }
    return index;
  }

  static int _findStartXref(Uint8List bytes) {
    final from = bytes.length > 2048 ? bytes.length - 2048 : 0;
    final index = _lastIndexOf(bytes, 'startxref', from);
    if (index < 0) {
      // TODO: recovery mode — rebuild the xref by scanning for "N G obj".
      throw CosParseException('missing startxref');
    }
    return CosParser(bytes, offset: index + 'startxref'.length)
        .expectInteger();
  }

  static CosXrefSection _parseXrefSection(Uint8List bytes, int offset) {
    if (offset < 0 || offset >= bytes.length) {
      throw CosParseException('cross-reference offset out of range', offset);
    }
    final parser = CosParser(bytes, offset: offset);
    if (parser.peekToken().isKeyword('xref')) {
      return _parseXrefTable(parser);
    }
    return _parseXrefStream(parser);
  }

  static CosXrefSection _parseXrefTable(CosParser parser) {
    parser.expectKeyword('xref');
    final entries = <int, CosXrefEntry>{};
    while (parser.peekToken().type == CosTokenType.integer) {
      final start = parser.expectInteger();
      final count = parser.expectInteger();
      for (var i = 0; i < count; i++) {
        final first = parser.expectInteger();
        final second = parser.expectInteger();
        final kind = parser.nextToken();
        final objectNumber = start + i;
        if (kind.isKeyword('n')) {
          entries.putIfAbsent(
              objectNumber, () => CosXrefEntry.inUse(first, second));
        } else if (kind.isKeyword('f')) {
          entries.putIfAbsent(objectNumber, () => const CosXrefEntry.free());
        } else {
          throw CosParseException('invalid xref entry type', kind.offset);
        }
      }
    }
    parser.expectKeyword('trailer');
    final trailer = parser.parseObject();
    if (trailer is! CosDictionary) {
      throw CosParseException('trailer is not a dictionary');
    }
    return CosXrefSection(entries, trailer);
  }

  static CosXrefSection _parseXrefStream(CosParser parser) {
    final indirect = parser.parseIndirectObject();
    final object = indirect.object;
    if (object is! CosStream) {
      throw CosParseException('expected a cross-reference stream');
    }
    final dict = object.dictionary;
    // xref stream dictionary entries must be direct (no resolver available
    // before the xref itself is loaded)
    final data = decodeStream(object);

    final w = dict['W'];
    final size = dict['Size'];
    if (w is! CosArray || w.length < 3 || size is! CosInteger) {
      throw CosParseException('invalid /W or /Size in cross-reference stream');
    }
    final widths = [
      for (final field in w.items)
        field is CosInteger
            ? field.value
            : throw CosParseException('invalid /W entry'),
    ];
    final index = dict['Index'];
    final ranges = index is CosArray
        ? [
            for (final v in index.items)
              v is CosInteger
                  ? v.value
                  : throw CosParseException('invalid /Index entry'),
          ]
        : [0, size.value];

    final entries = <int, CosXrefEntry>{};
    final rowLength = widths.fold(0, (a, b) => a + b);
    var pos = 0;
    for (var r = 0; r + 1 < ranges.length; r += 2) {
      final start = ranges[r];
      final count = ranges[r + 1];
      for (var i = 0; i < count && pos + rowLength <= data.length; i++) {
        final fields = <int>[];
        for (final width in widths) {
          var value = 0;
          for (var k = 0; k < width; k++) {
            value = (value << 8) | data[pos++];
          }
          fields.add(value);
        }
        // a zero-width type field defaults to "in use" (§7.5.8.3)
        final type = widths[0] == 0 ? 1 : fields[0];
        final objectNumber = start + i;
        switch (type) {
          case 0:
            entries.putIfAbsent(objectNumber, () => const CosXrefEntry.free());
          case 1:
            entries.putIfAbsent(objectNumber,
                () => CosXrefEntry.inUse(fields[1], fields[2]));
          case 2:
            entries.putIfAbsent(objectNumber,
                () => CosXrefEntry.compressed(fields[1], fields[2]));
        }
      }
    }
    return CosXrefSection(entries, dict);
  }
}

/// A decoded /Type /ObjStm: many small objects packed into one stream.
class _ObjectStream {
  _ObjectStream(this.data, int count, this.first) {
    final parser = CosParser(data);
    for (var i = 0; i < count; i++) {
      _index.add((parser.expectInteger(), parser.expectInteger()));
    }
  }

  final Uint8List data;

  /// Offset of the first object, relative to the decoded data.
  final int first;

  /// (object number, relative offset) pairs from the stream header.
  final List<(int, int)> _index = [];

  CosObject objectByNumber(int objectNumber, int hintIndex) {
    var entry = hintIndex >= 0 &&
            hintIndex < _index.length &&
            _index[hintIndex].$1 == objectNumber
        ? _index[hintIndex]
        : null;
    if (entry == null) {
      // the xref's index hint was wrong; fall back to a number lookup
      for (final candidate in _index) {
        if (candidate.$1 == objectNumber) {
          entry = candidate;
          break;
        }
      }
    }
    if (entry == null) {
      throw CosParseException(
          'object $objectNumber not found in its object stream');
    }
    return CosParser(data, offset: first + entry.$2).parseObject();
  }
}

int _indexOf(Uint8List bytes, String pattern, int from, [int? limit]) {
  final end = (limit ?? bytes.length) - pattern.length;
  for (var p = from; p <= end; p++) {
    var match = true;
    for (var i = 0; i < pattern.length; i++) {
      if (bytes[p + i] != pattern.codeUnitAt(i)) {
        match = false;
        break;
      }
    }
    if (match) return p;
  }
  return -1;
}

int _lastIndexOf(Uint8List bytes, String pattern, int from) {
  for (var p = bytes.length - pattern.length; p >= from; p--) {
    var match = true;
    for (var i = 0; i < pattern.length; i++) {
      if (bytes[p + i] != pattern.codeUnitAt(i)) {
        match = false;
        break;
      }
    }
    if (match) return p;
  }
  return -1;
}
