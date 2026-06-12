// pdf.js test corpus — rasterization smoke pass.
//
// Every corpus page renders through the real pipeline (interpreter →
// display list → raster), which is what exercises the image decoders
// (JBIG2, JPX, CCITT, JPEG flavors, PNG predictors) that the pure-Dart
// corpus test never touches. There are no baselines here — the pin is
// that nothing throws and nothing hangs; pixel regressions are the Ghent
// suite's job. Expectations (passwords, unopenable fuzz files) mirror
// packages/pdf_graphics/test/pdfjs_corpus_test.dart.
//
// For visual review, set PDFJS_RENDER_OUT to write PNGs plus an index.html:
//   PDFJS_RENDER_OUT=../../test_corpora/pdfjs/_renders \
//     fvm flutter test test/pdfjs_render_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';

import 'render_gallery.dart';
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
  final renderOut = Platform.environment['PDFJS_RENDER_OUT'];
  final gallery =
      renderOut == null ? null : RenderGallery(Directory(renderOut));
  final visualMaxPages = _envPositiveInt('PDFJS_RENDER_MAX_PAGES', maxPages);
  final visualPixelRatio = _envPositiveDouble('PDFJS_RENDER_PIXEL_RATIO', 1.0);

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
        final pageLimit = gallery == null ? maxPages : visualMaxPages;
        for (var i = 0; i < pages && i < pageLimit; i++) {
          final image = await PdfPageRenderer.renderImage(doc.page(i),
                  pixelRatio: visualPixelRatio)
              .timeout(const Duration(seconds: 90));
          expect(image.width, greaterThan(0));
          expect(image.height, greaterThan(0));
          if (gallery != null) {
            await gallery.add(pdfName: name, page: i, image: image);
          }
          image.dispose();
        }
      });
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}

int _envPositiveInt(String name, int fallback) {
  final value = int.tryParse(Platform.environment[name] ?? '');
  return value == null || value < 1 ? fallback : value;
}

double _envPositiveDouble(String name, double fallback) {
  final value = double.tryParse(Platform.environment[name] ?? '');
  return value == null || value <= 0 ? fallback : value;
}
