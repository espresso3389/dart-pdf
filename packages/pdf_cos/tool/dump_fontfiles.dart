// Debug aid: count embedded font program types per document.
//   dart tool/dump_fontfiles.dart <file.pdf> ...
import 'dart:io';
import 'package:pdf_cos/pdf_cos.dart';

void main(List<String> args) {
  for (final path in args) {
    try {
      final doc = CosDocument.open(File(path).readAsBytesSync());
      final counts = <String, int>{};
      for (final number in doc.objectNumbers.toList()) {
        final obj = doc.getObject(number, 0);
        if (obj is! CosDictionary) continue;
        if (obj.typeName != 'FontDescriptor') continue;
        for (final key in ['FontFile', 'FontFile2', 'FontFile3']) {
          if (obj[key] == null) continue;
          var label = key;
          if (key == 'FontFile3') {
            final file = doc.resolve(obj[key]);
            if (file is CosStream) {
              label = '$key/${doc.resolve(file.dictionary['Subtype'])}';
            }
          }
          counts[label] = (counts[label] ?? 0) + 1;
        }
      }
      if (counts.isNotEmpty) {
        stdout.writeln('$counts  ${path.split('/').last}');
      }
    } on Object {
      // skip
    }
  }
}
