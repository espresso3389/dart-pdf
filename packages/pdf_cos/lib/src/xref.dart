import 'objects.dart';

enum CosXrefEntryType { free, inUse, compressed }

/// One cross-reference entry: where to find an object.
class CosXrefEntry {
  const CosXrefEntry.free()
      : type = CosXrefEntryType.free,
        offset = 0,
        generation = 0,
        streamObjectNumber = 0,
        indexInStream = 0;

  const CosXrefEntry.inUse(this.offset, this.generation)
      : type = CosXrefEntryType.inUse,
        streamObjectNumber = 0,
        indexInStream = 0;

  const CosXrefEntry.compressed(this.streamObjectNumber, this.indexInStream)
      : type = CosXrefEntryType.compressed,
        offset = 0,
        generation = 0;

  final CosXrefEntryType type;

  /// Byte offset of the object, for [CosXrefEntryType.inUse] entries.
  final int offset;
  final int generation;

  /// Object number of the containing object stream, for
  /// [CosXrefEntryType.compressed] entries.
  final int streamObjectNumber;
  final int indexInStream;
}

/// One parsed cross-reference section (a table or stream) and its trailer.
class CosXrefSection {
  CosXrefSection(this.entries, this.trailer);

  final Map<int, CosXrefEntry> entries;
  final CosDictionary trailer;
}
