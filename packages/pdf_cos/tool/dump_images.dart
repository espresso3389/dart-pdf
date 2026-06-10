// Debug aid: list every image XObject in a document with its filters.
//   dart tool/dump_images.dart <file.pdf>
import 'dart:io';
import 'package:pdf_cos/pdf_cos.dart';

void main(List<String> args) {
  final doc = CosDocument.open(File(args[0]).readAsBytesSync());
  final seen = <int>{};
  final counts = <String, int>{};
  for (final number in doc.objectNumbers.toList()) {
    final obj = doc.getObject(number, 0);
    if (obj is! CosStream) continue;
    final subtype = obj.dictionary['Subtype'];
    if (subtype is! CosName || subtype.value != 'Image') continue;
    if (!seen.add(number)) continue;
    final filter = doc.resolve(obj.dictionary['Filter']);
    final w = doc.resolve(obj.dictionary['Width']);
    final h = doc.resolve(obj.dictionary['Height']);
    final cs = doc.resolve(obj.dictionary['ColorSpace']);
    final key = filter.toString();
    counts[key] = (counts[key] ?? 0) + 1;
    if ((counts[key] ?? 0) <= 3) {
      stdout.writeln('obj $number: $filter ${w}x$h cs=$cs '
          'smask=${obj.dictionary['SMask'] != null}');
    }
  }
  stdout.writeln('--- filter counts: $counts');
}
