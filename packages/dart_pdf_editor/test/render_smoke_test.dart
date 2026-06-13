// Renders page 1 to a PNG, as a pipeline smoke test.
//
// In CI this renders the built-in fixture. Locally, point it at any file:
//   PDF_PATH=/path/to/file.pdf PDF_PAGE=0 flutter test test/render_smoke_test.dart
// Output: /tmp/dart_pdf_render.png (override with PNG_OUT).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

/// flutter_test replaces every font with Ahem blocks; load real system
/// fonts (macOS paths) so rendered text is legible. Best-effort.
Future<void> loadSystemFonts() async {
  const fonts = {
    'Helvetica': ['/System/Library/Fonts/Helvetica.ttc'],
    'Times New Roman': [
      '/System/Library/Fonts/Supplemental/Times New Roman.ttf'
    ],
    'Courier': ['/System/Library/Fonts/Supplemental/Courier New.ttf'],
    'STSong': ['/System/Library/Fonts/Supplemental/Songti.ttc'],
    'Songti SC': ['/System/Library/Fonts/Supplemental/Songti.ttc'],
    'Heiti SC': ['/System/Library/Fonts/STHeiti Medium.ttc'],
    'Hiragino Sans GB': ['/System/Library/Fonts/Hiragino Sans GB.ttc'],
  };
  for (final entry in fonts.entries) {
    for (final path in entry.value) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final bytes = file.readAsBytesSync();
        final loader = FontLoader(entry.key)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      } catch (_) {
        // skip fonts the engine refuses; Ahem fallback still proves layout
      }
    }
  }
}

void main() {
  testWidgets('renders a page to PNG', (tester) async {
    await tester.runAsync(() async {
      await loadSystemFonts();

      final pdfPath = Platform.environment['PDF_PATH'];
      final pageIndex =
          int.tryParse(Platform.environment['PDF_PAGE'] ?? '') ?? 0;
      final bytes =
          pdfPath == null ? buildClassicPdf() : File(pdfPath).readAsBytesSync();

      final doc = PdfDocument.open(bytes);
      final page = doc.page(pageIndex.clamp(0, doc.pageCount - 1));
      final image = await PdfPageRenderer.renderImage(page, pixelRatio: 2);

      expect(image.width, greaterThan(0));
      expect(image.height, greaterThan(0));

      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = Platform.environment['PNG_OUT'] ?? '/tmp/dart_pdf_render.png';
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
      // ignore: avoid_print
      print('rendered ${image.width}x${image.height} -> $out');
    });
  });
}
