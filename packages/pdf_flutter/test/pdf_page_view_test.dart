import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

void main() {
  testWidgets('PdfPageView reserves the page aspect ratio', (tester) async {
    final doc = PdfDocument.open(buildClassicPdf());
    await tester.pumpWidget(
      Center(child: PdfPageView(page: doc.page(0))),
    );
    final size = tester.getSize(find.byType(PdfPageView));
    // US Letter: 612 x 792
    expect(
        size.width / size.height, moreOrLessEquals(612 / 792, epsilon: 1e-6));
  });

  testWidgets('raising scale re-rasterizes at higher resolution',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    final doc = PdfDocument.open(buildClassicPdf());
    final page = doc.page(0);
    // lay out at exactly the page's point width so scale is the only factor
    Widget at(double scale) => Center(
        child:
            SizedBox(width: 612, child: PdfPageView(page: page, scale: scale)));

    await tester.pumpWidget(at(1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final base = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(base.width, 612);

    await tester.pumpWidget(at(3));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final zoomed = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(zoomed.width, 612 * 3);
  });

  testWidgets('raster resolution follows the on-screen width', (tester) async {
    // Regression: rasters were sized from the page's nominal point size,
    // so a page stretched across a wide window (or a big external
    // display) was upscaled and blurry.
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    final doc = PdfDocument.open(buildClassicPdf());
    final page = doc.page(0);
    Widget at(double width) =>
        Center(child: SizedBox(width: width, child: PdfPageView(page: page)));

    await tester.pumpWidget(at(800));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final wide = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(wide.width, 800);

    await tester.pumpWidget(at(306));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final narrow = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(narrow.width, 306);
  });

  testWidgets('raster resolution is capped at deep zoom', (tester) async {
    final doc = PdfDocument.open(buildClassicPdf());
    await tester.pumpWidget(
      Center(child: PdfPageView(page: doc.page(0), scale: 1000)),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    // 612x792 capped to ~2^24 total pixels (plus ceil() rounding) and
    // 8192 per side
    expect(image.width * image.height, lessThan((1 << 24) * 1.001));
    expect(image.width, lessThanOrEqualTo(8192));
    expect(image.height, lessThanOrEqualTo(8192));
  });
}
