// pdf.js test corpus — rasterization smoke pass.
//
// Every corpus page renders through the real pipeline (interpreter →
// display list → raster), which is what exercises the image decoders
// (JBIG2, JPX, CCITT, JPEG flavors, PNG predictors) that the pure-Dart
// corpus test never touches. There are no baselines here — the pin is
// that nothing throws and nothing hangs; pixel regressions are the Ghent
// suite's job. Expectations (passwords, unopenable fuzz files) mirror
// packages/pdf_graphics/test/pdfjs_corpus_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';

import 'render_smoke_test.dart' show loadSystemFonts;

const passwords = {
  'issue6010_1.pdf': 'abc',
  'issue6010_2.pdf': 'æøå',
  'issue15893_reduced.pdf': 'test',
  'bug1782186.pdf': 'Hello',
  'issue3371.pdf': 'ELXRTQWS',
  'encrypted-attachment.pdf': '000000',
};

/// Files the pure-Dart corpus test pins as not opening (fuzzed beyond
/// recovery) or demanding a password we don't have.
const skipped = {
  'GHOSTSCRIPT-698804-1-fuzzed.pdf',
  'REDHAT-1531897-0.pdf',
  'poppler-395-0-fuzzed.pdf',
  'poppler-742-0-fuzzed.pdf',
  'poppler-85140-0.pdf',
  'poppler-937-0-fuzzed.pdf',
  'print_protection.pdf',
};

/// Pages rendered per file: enough to hit every codec the file carries
/// without rasterizing all of a long document.
const maxPages = 5;

void main() {
  final root = Directory('../../test_corpora/pdfjs');
  if (!root.existsSync()) {
    test('pdf.js suite', skip: 'test_corpora/pdfjs not found', () {});
    return;
  }

  final files = root
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.pdf'))
      .where((f) => !skipped.contains(f.uri.pathSegments.last))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    testWidgets(name, (tester) async {
      await tester.runAsync(() async {
        await loadSystemFonts();
        final doc = PdfDocument.open(file.readAsBytesSync(),
            password: passwords[name] ?? '');
        final pages = doc.pageCount;
        for (var i = 0; i < pages && i < maxPages; i++) {
          final image =
              await PdfPageRenderer.renderImage(doc.page(i), pixelRatio: 1.0)
                  .timeout(const Duration(seconds: 90));
          expect(image.width, greaterThan(0));
          image.dispose();
        }
      });
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
