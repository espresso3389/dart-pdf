// Debug aid: dump the font dictionaries a page references.
//   dart tool/dump_fonts.dart <file.pdf> [pageIndex]
import 'dart:io';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';

void main(List<String> args) {
  final doc = PdfDocument.open(File(args[0]).readAsBytesSync());
  final pageIndex = args.length > 1 ? int.parse(args[1]) : 0;
  final cos = doc.cos;
  final fonts = cos.resolve(doc.page(pageIndex).resources['Font']);
  if (fonts is! CosDictionary) {
    stdout.writeln('no fonts');
    return;
  }
  fonts.entries.forEach((name, ref) {
    final font = cos.resolve(ref);
    if (font is! CosDictionary) return;
    stdout.writeln('/$name:');
    for (final key in [
      'Subtype', 'BaseFont', 'FontMatrix', 'FirstChar', 'Encoding',
    ]) {
      final value = cos.resolve(font[key]);
      if (value is! CosNull) stdout.writeln('  /$key $value');
    }
    final widths = cos.resolve(font['Widths']);
    if (widths is CosArray) {
      final sample = widths.items.take(8).map((w) => cos.resolve(w)).toList();
      stdout.writeln('  /Widths (first 8): $sample');
    }
  });
}
