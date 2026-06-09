import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';

import 'page.dart';

/// A PDF document with page-level semantics on top of the COS layer.
class PdfDocument {
  PdfDocument._(this.cos);

  /// The underlying COS-level document, for anything not surfaced here yet.
  final CosDocument cos;

  static PdfDocument open(Uint8List bytes) =>
      PdfDocument._(CosDocument.open(bytes));

  String get version => cos.version;

  CosDictionary get catalog => cos.catalog;

  CosDictionary get _pagesRoot {
    final pages = cos.resolve(catalog['Pages']);
    if (pages is! CosDictionary) {
      throw CosParseException('catalog has no /Pages tree');
    }
    return pages;
  }

  int get pageCount {
    final count = cos.resolve(_pagesRoot['Count']);
    if (count is CosInteger && count.value >= 0) return count.value;
    return _countPages(_pagesRoot, <CosDictionary>{});
  }

  /// Document information dictionary (/Title, /Author, ...) as text.
  Map<String, String> get info {
    final dict = cos.resolve(cos.trailer['Info']);
    if (dict is! CosDictionary) return const {};
    final result = <String, String>{};
    dict.entries.forEach((key, value) {
      final v = cos.resolve(value);
      if (v is CosString) result[key] = v.text;
      if (v is CosName) result[key] = v.value;
    });
    return result;
  }

  /// Returns page [index] (zero-based), with inheritable attributes
  /// (Resources, MediaBox, CropBox, Rotate) resolved along the tree path.
  PdfPage page(int index) {
    if (index < 0) {
      throw RangeError.range(index, 0, null, 'index');
    }
    // TODO: use /Count on intermediate nodes to skip subtrees instead of
    // walking every leaf — matters for thousand-page documents.
    final counter = _Counter(index);
    final found =
        _findPage(_pagesRoot, counter, const _Inherited(), <CosDictionary>{});
    if (found == null) {
      throw RangeError('page index $index out of range: document has only '
          '${index - counter.value} reachable pages');
    }
    return found;
  }

  bool _isLeaf(CosDictionary node) =>
      node.typeName == 'Page' || !node.containsKey('Kids');

  int _countPages(CosDictionary node, Set<CosDictionary> visited) {
    if (!visited.add(node)) return 0;
    if (_isLeaf(node)) return 1;
    final kids = cos.resolve(node['Kids']);
    if (kids is! CosArray) return 0;
    var total = 0;
    for (final kid in kids.items) {
      final child = cos.resolve(kid);
      if (child is CosDictionary) total += _countPages(child, visited);
    }
    return total;
  }

  PdfPage? _findPage(CosDictionary node, _Counter remaining,
      _Inherited inherited, Set<CosDictionary> visited) {
    if (!visited.add(node)) return null;
    final merged = inherited.mergedWith(node, cos);
    if (_isLeaf(node)) {
      if (remaining.value == 0) {
        return PdfPage(
          document: this,
          dict: node,
          resources: merged.resources,
          mediaBoxArray: merged.mediaBox,
          cropBoxArray: merged.cropBox,
          rotate: merged.rotate,
        );
      }
      remaining.value--;
      return null;
    }
    final kids = cos.resolve(node['Kids']);
    if (kids is! CosArray) return null;
    for (final kid in kids.items) {
      final child = cos.resolve(kid);
      if (child is! CosDictionary) continue;
      final found = _findPage(child, remaining, merged, visited);
      if (found != null) return found;
    }
    return null;
  }
}

class _Counter {
  _Counter(this.value);
  int value;
}

/// Attributes that inherit down the page tree (§7.7.3.4).
class _Inherited {
  const _Inherited({this.resources, this.mediaBox, this.cropBox, this.rotate});

  final CosDictionary? resources;
  final CosArray? mediaBox;
  final CosArray? cropBox;
  final int? rotate;

  _Inherited mergedWith(CosDictionary node, CosDocument cos) {
    final res = cos.resolve(node['Resources']);
    final media = cos.resolve(node['MediaBox']);
    final crop = cos.resolve(node['CropBox']);
    final rot = cos.resolve(node['Rotate']);
    return _Inherited(
      resources: res is CosDictionary ? res : resources,
      mediaBox: media is CosArray ? media : mediaBox,
      cropBox: crop is CosArray ? crop : cropBox,
      rotate: rot is CosInteger ? rot.value : rotate,
    );
  }
}
