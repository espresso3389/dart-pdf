// Debug aid: print a Type3 font's first CharProc streams.
//   dart tool/dump_charproc.dart <file.pdf> <pageIndex>
import 'dart:io';
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart' as pd;

void main(List<String> args) async {
  final doc = pd.PdfDocument.open(File(args[0]).readAsBytesSync());
  final cos = doc.cos;
  final fonts =
      cos.resolve(doc.page(int.parse(args[1])).resources['Font']);
  if (fonts is! CosDictionary) return;
  for (final entry in fonts.entries.entries) {
    final font = cos.resolve(entry.value);
    if (font is! CosDictionary) continue;
    final subtype = font['Subtype'];
    if (subtype is! CosName || subtype.value != 'Type3') continue;
    stdout.writeln('/${entry.key}:');
    final procs = cos.resolve(font['CharProcs']);
    if (procs is! CosDictionary) {
      stdout.writeln('  no CharProcs!');
      continue;
    }
    var shown = 0;
    for (final procEntry in procs.entries.entries) {
      if (shown++ >= 2) break;
      final stream = cos.resolve(procEntry.value);
      if (stream is! CosStream) continue;
      final data = cos.decodeStreamData(stream);
      final text = String.fromCharCodes(
          data.sublist(0, data.length > 120 ? 120 : data.length));
      stdout.writeln('  /${procEntry.key} (${data.length}b): '
          '${text.replaceAll('\n', ' ')}');
    }
    final resources = cos.resolve(font['Resources']);
    stdout.writeln('  resources: ${resources is CosDictionary ? resources.entries.keys.toList() : resources}');
    break;
  }
}
