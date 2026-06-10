import 'dart:io';
import 'package:pdf_cos/pdf_cos.dart';

void main(List<String> args) {
  final doc = CosDocument.open(File(args[0]).readAsBytesSync());
  final props = doc.resolve(doc.catalog['OCProperties']);
  if (props is! CosDictionary) {
    stdout.writeln('no OCProperties');
    return;
  }
  final ocgs = doc.resolve(props['OCGs']);
  if (ocgs is CosArray) {
    for (final ref in ocgs.items) {
      final ocg = doc.resolve(ref);
      if (ocg is CosDictionary) {
        stdout.writeln('OCG $ref: ${doc.resolve(ocg['Name'])}');
      }
    }
  }
  final d = doc.resolve(props['D']);
  if (d is CosDictionary) {
    stdout.writeln('D /BaseState ${doc.resolve(d['BaseState'])}');
    stdout.writeln('D /ON ${doc.resolve(d['ON'])}');
    stdout.writeln('D /OFF ${doc.resolve(d['OFF'])}');
  }
}
