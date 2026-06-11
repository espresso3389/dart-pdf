part of 'editor.dart';

/// A self-contained copy of one annotation: its dictionary with every
/// referenced object — appearance streams included — resolved and copied
/// inline, detached from the document it came from.
///
/// Snapshots survive edits, undo, and even closing the source document,
/// which makes them the clipboard payload for copy/paste of annotations,
/// including across documents. Capture with [capture], paste with
/// [PdfAnnotationClipboard.pasteAnnotation].
class PdfAnnotationSnapshot {
  PdfAnnotationSnapshot._(this._dict, this.subtype, this.rect);

  /// Fully detached: no [CosReference]s, streams held inline. Pastes
  /// re-copy it ([_materialize]), so one snapshot can paste many times
  /// without the copies sharing mutable structure.
  final CosDictionary _dict;

  /// The /Subtype name ('Square', 'Ink', 'FreeText', ...).
  final String subtype;

  /// The source /Rect in its page's space — paste offsets are relative
  /// to this.
  final PdfRect rect;

  /// Entries that don't travel: the page link (/P), reply threads and
  /// popups (whose /Parent points back into the source document), the
  /// unique name, struct-tree and optional-content wiring.
  static const _dropped = {
    'P', 'Popup', 'Parent', 'IRT', 'RT', 'NM', 'StructParent', 'OC', //
  };

  /// Captures [annotation] from [document] as a detached snapshot.
  ///
  /// Popups belong to their parent annotation, and links and form
  /// widgets are interactive objects whose targets (destinations, the
  /// AcroForm field tree) cannot travel with a copy — those return null.
  static PdfAnnotationSnapshot? capture(
      PdfDocument document, PdfAnnotation annotation) {
    if (const {'Popup', 'Widget', 'Link'}.contains(annotation.subtype)) {
      return null;
    }
    final copier = _SnapshotCopier(document);
    final out = CosDictionary();
    annotation.dict.entries.forEach((key, value) {
      if (_dropped.contains(key)) return;
      out[key] = copier.copy(value);
    });
    return PdfAnnotationSnapshot._(out, annotation.subtype, annotation.rect);
  }

  CosDictionary _materialize() => _copyDetached(_dict) as CosDictionary;
}

/// Pure structural copy of an already-detached tree (no references to
/// resolve — [PdfAnnotationSnapshot] guarantees none survive capture).
CosObject _copyDetached(CosObject value) {
  switch (value) {
    case CosStream stream:
      return CosStream(_copyDetached(stream.dictionary) as CosDictionary,
          Uint8List.fromList(stream.rawBytes));
    case CosDictionary dict:
      final out = CosDictionary();
      dict.entries.forEach((key, item) => out[key] = _copyDetached(item));
      return out;
    case CosArray array:
      return CosArray([for (final item in array.items) _copyDetached(item)]);
    case CosString string:
      return CosString(Uint8List.fromList(string.bytes), isHex: string.isHex);
    default:
      return value; // names, numbers, booleans, null are immutable
  }
}

/// Deep-copies an annotation's object graph out of [source] into fully
/// direct (inline) structures: references resolve and copy in place,
/// shared targets duplicate, reference cycles break to null. Page-tree
/// dictionaries copy as null so a stray /P-like entry can't drag the
/// whole document along.
class _SnapshotCopier {
  _SnapshotCopier(this.source);

  final PdfDocument source;
  final Set<CosReference> _visiting = {};

  CosObject copy(CosObject value) {
    switch (value) {
      case CosReference ref:
        if (!_visiting.add(ref)) return CosNull.instance; // cycle
        final out = copy(source.cos.resolve(ref));
        _visiting.remove(ref);
        return out;
      case CosStream stream:
        final bytes = _payloadOf(stream);
        final out = CosStream(CosDictionary(), bytes);
        stream.dictionary.entries.forEach((key, item) {
          if (key == 'Length') return; // recomputed below
          out.dictionary[key] = copy(item);
        });
        out.dictionary['Length'] = CosInteger(bytes.length);
        return out;
      case CosDictionary dict:
        if (dict.typeName == 'Page' || dict.typeName == 'Pages') {
          return CosNull.instance; // never cross into the page tree
        }
        final out = CosDictionary();
        dict.entries.forEach((key, item) => out[key] = copy(item));
        return out;
      case CosArray array:
        return CosArray([for (final item in array.items) copy(item)]);
      case CosString string:
        return CosString(Uint8List.fromList(string.bytes),
            isHex: string.isHex);
      default:
        return value;
    }
  }

  /// Stream payload as plain (decrypted) bytes with the /Filter chain
  /// intact — same approach as page imports: stop the decode before the
  /// first filter so only the encryption comes off.
  Uint8List _payloadOf(CosStream stream) {
    final cos = source.cos;
    if (!cos.isEncrypted) return stream.rawBytes;
    final filter = cos.resolve(stream.dictionary['Filter']);
    final first = switch (filter) {
      CosName(:final value) => value,
      CosArray array when array.length > 0 => switch (cos.resolve(array[0])) {
          CosName(:final value) => value,
          _ => null,
        },
      _ => null,
    };
    return cos.decodeStreamData(stream, stopBeforeFilter: first);
  }
}

/// Pasting captured annotations ([PdfAnnotationSnapshot]) into a page.
extension PdfAnnotationClipboard on PdfEditor {
  /// Pastes [snapshot] onto page [pageIndex], its geometry shifted by
  /// ([dx], [dy]) page units.
  ///
  /// Each call materializes an independent copy — pasting twice yields
  /// two annotations. Streams (the appearance) become fresh indirect
  /// objects per §7.3.8, and the annotation appends to the page's
  /// /Annots, so it paints on top (§12.5.2).
  void pasteAnnotation(int pageIndex, PdfAnnotationSnapshot snapshot,
      {double dx = 0, double dy = 0}) {
    final dict = snapshot._materialize();
    final rect = snapshot.rect;
    dict['Rect'] = _rectArray(PdfRect(
      rect.left + dx,
      rect.bottom + dy,
      rect.right + dx,
      rect.top + dy,
    ));
    for (final key in const ['QuadPoints', 'L', 'Vertices', 'CL']) {
      final shifted = _shiftPoints(dict[key], dx, dy);
      if (shifted != null) dict[key] = shifted;
    }
    final ink = dict['InkList'];
    if (ink is CosArray) {
      dict['InkList'] = CosArray([
        for (final stroke in ink.items) _shiftPoints(stroke, dx, dy) ?? stroke,
      ]);
    }
    _hoistStreams(dict);

    final page = document.page(pageIndex);
    final annotRef = _updater.addObject(dict);
    final raw = page.dict['Annots'];
    final resolved = document.cos.resolve(raw);
    if (resolved is CosArray) {
      resolved.items.add(annotRef);
      if (raw is CosReference) {
        _updater.replaceObject(raw.objectNumber, resolved);
      } else {
        _updater.markChanged(page.dict);
      }
    } else {
      page.dict['Annots'] = CosArray([annotRef]);
      _updater.markChanged(page.dict);
    }
  }

  /// Replaces every inline [CosStream] in the tree with a reference to a
  /// freshly staged indirect object (children first, so a stream nested
  /// in another stream's /Resources hoists too).
  void _hoistStreams(CosObject node) {
    switch (node) {
      case CosDictionary dict:
        for (final key in dict.entries.keys.toList()) {
          final value = dict.entries[key]!;
          if (value is CosStream) {
            _hoistStreams(value.dictionary);
            dict[key] = _updater.addObject(value);
          } else {
            _hoistStreams(value);
          }
        }
      case CosArray array:
        for (var i = 0; i < array.items.length; i++) {
          final value = array.items[i];
          if (value is CosStream) {
            _hoistStreams(value.dictionary);
            array.items[i] = _updater.addObject(value);
          } else {
            _hoistStreams(value);
          }
        }
      default:
        break;
    }
  }
}
