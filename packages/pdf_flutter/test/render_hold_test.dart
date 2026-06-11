// Fast-scroll render hold: pages flying past during a fast scroll defer
// their (UI-thread) first interpretation so the frame rate — and the
// scrollbar — stay smooth; held pages render once the scroll settles.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

void main() {
  /// Lets the real async renderer make progress, then pumps a frame.
  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }

  Future<void> waitForRaster(WidgetTester tester) async {
    for (var i = 0; i < 50 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(find.byType(RawImage), findsWidgets);
  }

  testWidgets('PdfPageView.renderHold defers the first render until released',
      (tester) async {
    final document = PdfDocument.open(buildClassicPdf());
    final hold = ValueNotifier<bool>(true);
    addTearDown(hold.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
            width: 400, child: PdfPageView(page: document.page(0), renderHold: hold)),
      ),
    ));

    // held: however long we wait, the page keeps its paper placeholder
    for (var i = 0; i < 5; i++) {
      await settle(tester);
    }
    expect(find.byType(RawImage), findsNothing);

    hold.value = false;
    await waitForRaster(tester);
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
    await waitForRaster(tester);

    // a long jump animates 250ms at far past the velocity threshold
    unawaited(controller.jumpToPage(6));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      // give an unheld render every chance to (wrongly) complete
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    // mid-flight and just arrived (settle pending): the pages that flew
    // past — and the destination — still show their placeholders; page 0's
    // raster is long unmounted
    expect(find.byType(RawImage), findsNothing);

    // the scroll-settle timer releases the hold and the target renders
    await tester.pump(const Duration(milliseconds: 300));
    await waitForRaster(tester);
  });
}
