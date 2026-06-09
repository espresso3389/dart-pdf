import 'dart:typed_data';

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

/// Builds a minimal one-page PDF with a classic cross-reference table.
Uint8List buildClassicPdf() {
  const content = 'BT /F1 24 Tf 72 720 Td (Hello, world!) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefOffset = buffer.length;
  buffer
    ..write('xref\n0 ${objects.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer
    ..write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n')
    ..write('startxref\n$xrefOffset\n%%EOF\n');
  return ascii(buffer.toString());
}

/// Builds a PDF in the "modern" 1.5+ layout: an uncompressed cross-reference
/// stream, with the catalog and page tree packed into an object stream.
Uint8List buildXrefStreamPdf() {
  // objects 1 (catalog), 2 (pages), 3 (page) live inside object stream 4
  final inner = <(int, String)>[
    (1, '<< /Type /Catalog /Pages 2 0 R >>'),
    (2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    (3, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>'),
  ];
  var header = '';
  var payload = '';
  for (final (number, source) in inner) {
    header += '$number ${payload.length} ';
    payload += '$source ';
  }
  final objStmData = header + payload;
  final first = header.length;

  final out = StringBuffer('%PDF-1.5\n');
  final objStmOffset = out.length;
  out.write('4 0 obj\n<< /Type /ObjStm /N ${inner.length} /First $first '
      '/Length ${objStmData.length} >>\nstream\n$objStmData\nendstream\n'
      'endobj\n');

  final xrefOffset = out.length;
  // /W [1 4 2]: 1-byte type, 4-byte offset, 2-byte generation/index
  final rows = <List<int>>[
    [0, 0, 0xFFFF], // 0: head of the free list
    [2, 4, 0], // 1: in object stream 4, index 0
    [2, 4, 1],
    [2, 4, 2],
    [1, objStmOffset, 0], // 4: the object stream itself
    [1, xrefOffset, 0], // 5: this xref stream
  ];
  final xrefData = <int>[];
  for (final row in rows) {
    xrefData
      ..add(row[0])
      ..addAll([
        (row[1] >> 24) & 0xFF,
        (row[1] >> 16) & 0xFF,
        (row[1] >> 8) & 0xFF,
        row[1] & 0xFF,
      ])
      ..addAll([(row[2] >> 8) & 0xFF, row[2] & 0xFF]);
  }
  out.write('5 0 obj\n<< /Type /XRef /Size 6 /W [1 4 2] /Root 1 0 R '
      '/Length ${xrefData.length} >>\nstream\n');

  return (BytesBuilder()
        ..add(ascii(out.toString()))
        ..add(xrefData)
        ..add(ascii('\nendstream\nendobj\nstartxref\n$xrefOffset\n%%EOF\n')))
      .takeBytes();
}

/// Builds a [pageCount]-page PDF; page N shows the text "Page N".
Uint8List buildMultiPagePdf(int pageCount) {
  final objects = <String>[];
  final kids = [
    for (var i = 0; i < pageCount; i++) '${3 + i * 2} 0 R',
  ].join(' ');
  final fontNumber = 3 + pageCount * 2;
  objects.add('<< /Type /Catalog /Pages 2 0 R >>');
  objects.add('<< /Type /Pages /Kids [$kids] /Count $pageCount >>');
  for (var i = 0; i < pageCount; i++) {
    final content = 'BT /F1 24 Tf 72 720 Td (Page ${i + 1}) Tj ET';
    objects.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Contents ${4 + i * 2} 0 R '
        '/Resources << /Font << /F1 $fontNumber 0 R >> >> >>');
    objects.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');

  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefOffset = buffer.length;
  buffer
    ..write('xref\n0 ${objects.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer
    ..write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n')
    ..write('startxref\n$xrefOffset\n%%EOF\n');
  return ascii(buffer.toString());
}
