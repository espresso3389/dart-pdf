// Debug aid: decode a named form XObject on a page and summarize its ops.
//   dart tool/dump_form.dart <file.pdf> <pageIndex> <name> [grep]
import 'dart:io';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

void main(List<String> args) {
  final doc = PdfDocument.open(File(args[0]).readAsBytesSync());
  final cos = doc.cos;
  final page = doc.page(int.parse(args[1]));
  // the name may be a nested path, e.g. X1/X2
  var resources = page.resources;
  CosObject form = CosNull.instance;
  for (final part in args[2].split('/')) {
    final xobjects = cos.resolve(resources['XObject']);
    if (xobjects is! CosDictionary) {
      stdout.writeln('no XObject dict while resolving $part');
      return;
    }
    form = cos.resolve(xobjects[part]);
    if (form is! CosStream) {
      stdout.writeln('not a stream: $part -> $form');
      return;
    }
    final inner = cos.resolve(form.dictionary['Resources']);
    if (inner is CosDictionary) resources = inner;
  }
  if (form is! CosStream) return;
  final List<ContentOperation> ops;
  try {
    ops = ContentStreamParser.parse(cos.decodeStreamData(form));
  } catch (e) {
    stdout.writeln('DECODE/PARSE FAILED: $e');
    return;
  }
  stdout.writeln('${ops.length} ops');
  final counts = <String, int>{};
  for (final op in ops) {
    counts[op.operator] = (counts[op.operator] ?? 0) + 1;
  }
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln(sorted.take(18).map((e) => '${e.key}:${e.value}').join(' '));
  if (args.length > 3) {
    for (var i = 0; i < ops.length; i++) {
      final line = ops[i].toString();
      if (line.contains(args[3])) stdout.writeln('[$i] $line');
    }
  }
  // list this form's own XObjects
  final res = cos.resolve(form.dictionary['Resources']);
  if (res is CosDictionary) {
    final inner = cos.resolve(res['XObject']);
    if (inner is CosDictionary) {
      inner.entries.forEach((name, ref) {
        final x = cos.resolve(ref);
        if (x is CosStream) {
          stdout.writeln('  /$name ${cos.resolve(x.dictionary['Subtype'])} '
              'filter=${cos.resolve(x.dictionary['Filter'])} '
              'smask=${x.dictionary['SMask'] != null} '
              'group=${cos.resolve(x.dictionary['Group']) is! CosNull}');
        }
      });
    }
    final ext = cos.resolve(res['ExtGState']);
    if (ext is CosDictionary) {
      ext.entries.forEach((name, ref) {
        stdout.writeln('  gs /$name ${cos.resolve(ref)}');
      });
    }
  }
}
