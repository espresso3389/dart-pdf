import 'dart:io';
import 'package:pdf_cos/pdf_cos.dart';

void main(List<String> args) {
  final doc = CosDocument.open(File(args[0]).readAsBytesSync());
  final pages = doc.resolve(doc.catalog['Pages']) as CosDictionary;
  final page = doc.resolve((doc.resolve(pages['Kids']) as CosArray)[0])
      as CosDictionary;
  final res = doc.resolve(page['Resources']) as CosDictionary;
  final ext = doc.resolve(res['ExtGState']);
  if (ext is CosDictionary) {
    ext.entries.forEach((name, ref) {
      stdout.writeln('/$name ${doc.resolve(ref)}');
    });
  }
  final xobjects = doc.resolve(res['XObject']);
  if (xobjects is CosDictionary) {
    xobjects.entries.forEach((name, ref) {
      final x = doc.resolve(ref);
      if (x is CosStream) {
        stdout.writeln('/$name subtype=${doc.resolve(x.dictionary['Subtype'])} '
            'group=${doc.resolve(x.dictionary['Group'])} '
            'bbox=${doc.resolve(x.dictionary['BBox'])} '
            'matrix=${doc.resolve(x.dictionary['Matrix'])}');
      }
    });
  }
}
