// Fast-scroll render hold: pages flying past during a fast scroll defer
// their (UI-thread) first interpretation so the frame rate — and the
// scrollbar — stay smooth; held pages render once the scroll settles.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

void main() {
  /// Lets the real async renderer make progress, then pumps a frame.
  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(finder, findsWidgets);
  }

  // a full-page raster (vs the small fast-scroll previews, ≤200px)
  final fullRaster = find.byWidgetPredicate((w) =>
      w is RawImage &&
      w.image != null &&
      (w.image!.width > 200 || w.image!.height > 200));

  testWidgets('PdfPageView.renderHold defers the first render until released',
      (tester) async {
    final document = PdfDocument.open(buildClassicPdf());
    final hold = ValueNotifier<bool>(true);
    addTearDown(hold.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
            width: 400,
            child: PdfPageView(page: document.page(0), renderHold: hold)),
      ),
    ));

    // held: however long we wait, the page keeps its paper placeholder
    for (var i = 0; i < 5; i++) {
      await settle(tester);
    }
    expect(find.byType(RawImage), findsNothing);

    hold.value = false;
    await waitFor(tester, find.byType(RawImage));
  });

  testWidgets('a fast jump holds page rendering until the scroll settles',
      (tester) async {
    final document = PdfDocument.open(buildMultiPagePdf(8));
    final controller = PdfViewerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfViewer(
          document: document,
          controller: controller,
          initialFit: PdfViewerFit.width,
        ),
      ),
    ));
    await tester.pump();
    // an idle viewer renders normally
    await waitFor(tester, fullRaster);

    // a long jump animates 250ms at far past the velocity threshold
    unawaited(controller.jumpToPage(6));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      // give an unheld render every chance to (wrongly) complete
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    // mid-flight and just arrived (settle pending): no page got a FULL
    // render — page 0's raster is long unmounted, the destination is
    // held. (Low-res previews are allowed: that's the fast-scroll
    // preview feature, covered in page_preview_test.dart.)
    expect(fullRaster, findsNothing);

    // the scroll-settle timer releases the hold and the target renders
    await tester.pump(const Duration(milliseconds: 300));
    await waitFor(tester, fullRaster);
  });
}
