import 'dart:io';
import 'package:pdf_document/pdf_document.dart';

void main(List<String> args) {
  var files = 0, pages = 0, annots = 0, actions = 0, failures = 0;
  final byType = <String, int>{};
  for (final path in args) {
    try {
      final doc = PdfDocument.open(File(path).readAsBytesSync());
      files++;
      for (var i = 0; i < doc.pageCount; i++) {
        pages++;
        for (final a in doc.page(i).annotations) {
          annots++;
          byType[a.subtype] = (byType[a.subtype] ?? 0) + 1;
          final action = a.action;
          if (action != null) {
            actions++;
            if (action is PdfGoToAction &&
                action.destination.pageIndex >= doc.pageCount) {
              print('  !! $path p$i: dest page out of range');
            }
          }
        }
      }
    } catch (e) {
      failures++;
      print('FAIL $path: $e');
    }
  }
  print('$files files, $pages pages, $annots annotations '
      '($actions with actions), $failures failures');
  print(byType);
}
