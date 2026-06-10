import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

void main() {
  Future<PdfViewerController> pumpViewer(WidgetTester tester,
      {int pages = 5}) async {
    final controller = PdfViewerController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfViewer(
          document: PdfDocument.open(buildMultiPagePdf(pages)),
          controller: controller,
        ),
      ),
    ));
    await tester.pump();
    return controller;
  }

  testWidgets('reports the page count and renders page widgets',
      (tester) async {
    final controller = await pumpViewer(tester);
    expect(controller.pageCount, 5);
    expect(controller.currentPage, 0);
    expect(find.byType(PdfPageView), findsWidgets);
  });

  testWidgets('scrolling updates the current page', (tester) async {
    final controller = await pumpViewer(tester);
    await tester.drag(find.byType(PdfViewer), const Offset(0, -2500));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(controller.currentPage, greaterThan(0));
  });

  testWidgets('search finds matches and tracks the current one',
      (tester) async {
    final controller = await pumpViewer(tester);
    await tester.runAsync(() => controller.search('Page 4'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(controller.matchCount, 1);
    expect(controller.currentMatch, 0);
    expect(controller.isSearching, isFalse);
    // jumped to the match's page
    expect(controller.currentPage, 3);
  });

  testWidgets('match navigation wraps around', (tester) async {
    final controller = await pumpViewer(tester);
    await tester.runAsync(() => controller.search('Page'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.matchCount, 5);

    controller.nextMatch();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.currentMatch, 1);

    controller.previousMatch();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.currentMatch, 0);

    controller.previousMatch();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.currentMatch, 4); // wrapped

    controller.clearSearch();
    expect(controller.matchCount, 0);
  });

  testWidgets(
      'mounting next to an already-built ListenableBuilder does not '
      'notify during build', (tester) async {
    // Regression: _loadPages runs in initState (mid-build) and used to
    // notifyListeners synchronously, dirtying a sibling page indicator that
    // had already built this frame.
    final controller = PdfViewerController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          ListenableBuilder(
            listenable: controller,
            builder: (_, __) => Text('${controller.pageCount}'),
          ),
          Expanded(
            child: PdfViewer(
              document: PdfDocument.open(buildMultiPagePdf(3)),
              controller: controller,
            ),
          ),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
    await tester.pump(); // deferred notification lands
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('jumpToPage scrolls to the requested page', (tester) async {
    final controller = await pumpViewer(tester);
    controller.jumpToPage(4);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.currentPage, 4);
  });
}
