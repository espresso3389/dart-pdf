import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';

/// Where the demo's Flutter overlays sit, in PDF page coordinates. The
/// document's artwork draws matching slots at the same rects, so the
/// page-space ↔ view-space registration is visible on screen.
abstract final class DemoLayout {
  /// Page 1: badge showing the app counter the PDF links increment.
  static const counterBadge = PdfRect(300, 600, 380, 636);

  // page 2 widget slots
  static const clock = PdfRect(180, 630, 360, 670);
  static const counter = PdfRect(180, 570, 360, 610);
  static const toggle = PdfRect(180, 510, 280, 550);
  static const note = PdfRect(180, 440, 460, 490);
}

// page 1 link annotation rects (also drawn as buttons in the artwork)
const _incrementLink = PdfRect(72, 600, 280, 636);
const _messageLink = PdfRect(72, 540, 280, 576);
const _goToLink = PdfRect(72, 480, 280, 516);
const _nextPageLink = PdfRect(72, 420, 280, 456);
const _jsButton = PdfRect(72, 360, 280, 396);

String _rect(PdfRect r) => '[${r.left} ${r.bottom} ${r.right} ${r.top}]';

String _text(double x, double y, double size, String s) =>
    'BT /F1 $size Tf $x $y Td ($s) Tj ET\n';

/// A filled, stroked box with a centered-ish label: the demo's "button".
String _button(PdfRect r, String label) =>
    'q 0.92 0.94 1.00 rg ${r.left} ${r.bottom} ${r.width} ${r.height} re f '
    '0.25 0.35 0.85 RG 1 w ${r.left} ${r.bottom} ${r.width} ${r.height} re S Q\n'
    '${_text(r.left + 12, r.bottom + r.height / 2 - 4, 12, label)}';

/// An empty outlined slot a Flutter widget will sit in.
String _slot(PdfRect r) =>
    'q 0.55 0.55 0.55 RG 0.75 w ${r.left} ${r.bottom} ${r.width} ${r.height} re S Q\n';

String _link(PdfRect r, String action) =>
    '<< /Type /Annot /Subtype /Link /Rect ${_rect(r)} /A $action >>';

/// Builds the 3-page interactive demo document. All interactivity on
/// page 1 is plain PDF — link and widget annotations any conforming
/// viewer understands; the app reacts to them through PdfViewer.onAction.
/// Page 2 is the inverse direction: Flutter widgets drawn over the page.
Uint8List buildDemoPdf() {
  final page1 = StringBuffer()
    ..write(_text(72, 730, 22, 'dart-pdf interactivity demo'))
    ..write(_text(72, 702, 12,
        'The blue boxes are PDF link annotations. Tapping them drives the Flutter app.'))
    ..write(_button(_incrementLink, 'Increment the counter'))
    ..write(_slot(DemoLayout.counterBadge))
    ..write(_text(390, 614, 10, 'a live Flutter widget'))
    ..write(_button(_messageLink, 'Show a message'))
    ..write(_button(_goToLink, 'Go to the widgets page'))
    ..write(_button(_nextPageLink, 'Next page - a named action'))
    ..write(_button(_jsButton, 'Run JavaScript'))
    ..write(_text(72, 334, 10,
        'The script reaches the app as source text - dart-pdf never executes JavaScript.'));

  final page2 = StringBuffer()
    ..write(_text(72, 730, 22, 'Flutter widgets pinned to the page'))
    ..write(_text(72, 702, 12,
        'Each gray slot holds a live Flutter widget positioned in PDF coordinates.'))
    ..write(_text(72, 686, 12,
        'They scroll and zoom with the page - try pinch or ctrl+wheel.'))
    ..write(_text(72, 646, 12, 'Live clock'))
    ..write(_slot(DemoLayout.clock))
    ..write(_text(72, 586, 12, 'Counter'))
    ..write(_slot(DemoLayout.counter))
    ..write(_text(72, 526, 12, 'Switch'))
    ..write(_slot(DemoLayout.toggle))
    ..write(_text(72, 461, 12, 'Note'))
    ..write(_slot(DemoLayout.note))
    ..write(_text(72, 400, 10,
        'The counter here is the same app state the PDF link on page 1 increments.'));

  final page3 = StringBuffer()
    ..write(_text(72, 730, 22, 'You arrived via a GoTo link'))
    ..write(_text(72, 702, 12,
        'The viewer followed the destination internally - no app code involved.'));

  // page 2 is object 5 — the GoTo target
  final annots = '/Annots [ '
      '${_link(_incrementLink, '<< /S /URI /URI (app://counter/increment) >>')} '
      '${_link(_messageLink, '<< /S /URI /URI (app://message?text=Hello%20from%20the%20PDF) >>')} '
      '${_link(_goToLink, '<< /S /GoTo /D [5 0 R /XYZ null null null] >>')} '
      '${_link(_nextPageLink, '<< /S /Named /N /NextPage >>')} '
      '<< /Type /Annot /Subtype /Widget /FT /Btn /T (demoJs) '
      '/Rect ${_rect(_jsButton)} /A << /S /JavaScript '
      r'/JS (app.alert\(Hello from PDF JavaScript\)) >> >> '
      ']';

  final contents = [page1, page2, page3];
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>',
  ];
  for (var i = 0; i < 3; i++) {
    final content = contents[i].toString();
    objects.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Contents ${4 + i * 2} 0 R '
        '/Resources << /Font << /F1 9 0 R >> >> '
        '${i == 0 ? annots : ''}>>');
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
  return Uint8List.fromList(buffer.toString().codeUnits);
}
