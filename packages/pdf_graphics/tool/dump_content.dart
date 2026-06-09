// Debug aid: print the decoded content stream operations of a page.
//   dart tool/dump_content.dart <file.pdf> [pageIndex] [grep]
import 'dart:io';

import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

void main(List<String> args) {
  final doc = PdfDocument.open(File(args[0]).readAsBytesSync());
  final pageIndex = args.length > 1 ? int.parse(args[1]) : 0;
  final needle = args.length > 2 ? args[2] : null;
  final ops = ContentStreamParser.parse(doc.page(pageIndex).contentBytes());
  for (var i = 0; i < ops.length; i++) {
    final line = ops[i].toString();
    if (needle == null || line.contains(needle)) {
      stdout.writeln('[$i] $line');
    }
  }
}
