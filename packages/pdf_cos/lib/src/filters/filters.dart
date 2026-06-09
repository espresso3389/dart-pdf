import 'dart:typed_data';

import '../exceptions.dart';
import '../objects.dart';
import '../parser.dart';
import 'ascii.dart';
import 'flate.dart';

export 'ascii.dart';
export 'flate.dart';
export 'predictor.dart';

/// Decodes one stage of a stream's /Filter chain.
abstract class CosFilter {
  const CosFilter();

  Uint8List decode(Uint8List data, CosDictionary? params);
}

const Map<String, CosFilter> _filters = {
  'FlateDecode': FlateFilter(),
  'Fl': FlateFilter(),
  'ASCIIHexDecode': AsciiHexFilter(),
  'AHx': AsciiHexFilter(),
  'ASCII85Decode': Ascii85Filter(),
  'A85': Ascii85Filter(),
  // TODO: LZWDecode, RunLengthDecode, CCITTFaxDecode, JBIG2Decode.
  // DCTDecode/JPXDecode stay encoded; image decoding happens at render time.
};

/// Decodes a stream's payload by applying its /Filter chain in order.
///
/// [resolve] is used to chase indirect references inside /Filter,
/// /DecodeParms, and /Length entries.
Uint8List decodeStream(CosStream stream, {CosResolver? resolve}) {
  CosObject deref(CosObject? object) {
    var value = object ?? CosNull.instance;
    while (value is CosReference && resolve != null) {
      value = resolve(value);
    }
    return value;
  }

  final filterObject = deref(stream.dictionary['Filter']);
  final paramsObject =
      deref(stream.dictionary['DecodeParms'] ?? stream.dictionary['DP']);

  final names = <String>[];
  if (filterObject is CosName) names.add(filterObject.value);
  if (filterObject is CosArray) {
    for (final f in filterObject.items) {
      final r = deref(f);
      if (r is CosName) names.add(r.value);
    }
  }

  final params = <CosDictionary?>[];
  if (paramsObject is CosDictionary) params.add(paramsObject);
  if (paramsObject is CosArray) {
    for (final p in paramsObject.items) {
      final r = deref(p);
      params.add(r is CosDictionary ? r : null);
    }
  }

  var data = stream.rawBytes;
  for (var i = 0; i < names.length; i++) {
    final filter = _filters[names[i]];
    if (filter == null) throw UnsupportedFilterException(names[i]);
    data = filter.decode(data, i < params.length ? params[i] : null);
  }
  return data;
}
