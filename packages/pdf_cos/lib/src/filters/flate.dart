import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../objects.dart';
import 'filters.dart';

/// FlateDecode: zlib/deflate, optionally followed by a PNG/TIFF predictor.
class FlateFilter extends CosFilter {
  const FlateFilter();

  @override
  Uint8List decode(Uint8List data, CosDictionary? params) {
    final inflated = Uint8List.fromList(const ZLibDecoder().decodeBytes(data));
    return applyPredictor(inflated, params);
  }
}
