import 'dart:io';
import 'package:pdf_cos/pdf_cos.dart';

void main(List<String> args) {
  final doc = CosDocument.open(File(args[0]).readAsBytesSync());
  final pages = doc.resolve(doc.catalog['Pages']) as CosDictionary;
  final kids = doc.resolve(pages['Kids']) as CosArray;
  for (var i = 0; i < 2 && i < kids.length; i++) {
    final page = doc.resolve(kids[i]) as CosDictionary;
    stdout.writeln('page $i:');
    for (final key in ['MediaBox', 'CropBox', 'BleedBox', 'TrimBox', 'ArtBox', 'Rotate', 'UserUnit', 'Group']) {
      final v = doc.resolve(page[key]);
      if (v is! CosNull) stdout.writeln('  /$key $v');
    }
  }
}
