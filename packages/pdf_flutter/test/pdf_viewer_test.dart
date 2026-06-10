import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('mouse drag selects text and copy reaches the clipboard',
      (tester) async {
    final controller = await pumpViewer(tester);
    // fixture text 'Page 1' sits at 72,720..144,720 (24pt) on a 612-wide
    // page filling the 800px viewport
    const scale = 800 / 612;
    Offset view(double x, double y) => Offset(x * scale, (792 - y) * scale);

    // start just right of the run (inside the hit tolerance), drag left
    // past its start so the whole string is selected
    final pageViewState = tester.state(find.byType(PdfPageView).first);

    final gesture = await tester.startGesture(view(154, 720),
        kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-20, 0)); // pass the drag slop
    await tester.pump();
    await gesture.moveTo(view(50, 720));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(controller.selectedText, 'Page 1');
    expect(controller.hasSelection, isTrue);
    // selection painting must not reshape the tree and recreate the page
    // view (that drops its raster: a white flash)
    expect(tester.state(find.byType(PdfPageView).first),
        same(pageViewState));

    final copied = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String?);
      }
      return null;
    });
    await controller.copySelection();
    expect(copied, ['Page 1']);

    controller.clearSelection();
    await tester.pump();
    expect(controller.hasSelection, isFalse);
    // drain the double-tap recognizer's timeout timer
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('hovering text shows the text cursor', (tester) async {
    await pumpViewer(tester);
    const scale = 800 / 612;
    Offset view(double x, double y) => Offset(x * scale, (792 - y) * scale);

    MouseRegion region() => tester.widget<MouseRegion>(find
        .descendant(
            of: find.byType(PdfViewer), matching: find.byType(MouseRegion))
        .first);

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 7);
    await gesture.addPointer(location: view(300, 500)); // empty page area
    addTearDown(gesture.removePointer);
    await tester.pump();
    expect(region().cursor, MouseCursor.defer);

    await gesture.moveTo(view(100, 720)); // over 'Page 1'
    await tester.pump();
    expect(region().cursor, SystemMouseCursors.text);

    await gesture.moveTo(view(300, 500));
    await tester.pump();
    expect(region().cursor, MouseCursor.defer);

    // leaving the viewer entirely must also reset the cursor
    await gesture.moveTo(view(100, 720));
    await tester.pump();
    expect(region().cursor, SystemMouseCursors.text);
    await gesture.moveTo(const Offset(400, 900)); // outside the window
    await tester.pump();
    expect(region().cursor, MouseCursor.defer);
  });

  testWidgets('double-click with a mouse selects the word under it',
      (tester) async {
    final controller = await pumpViewer(tester);
    const scale = 800 / 612;
    final overText = Offset(100 * scale, (792 - 720) * scale);

    await tester.tapAt(overText, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(overText, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(controller.selectedText, 'Page');
    // and the viewer did not zoom
    expect(controller.zoom, 1);
  });

  testWidgets('ctrl+wheel zooms, plain wheel scrolls', (tester) async {
    final controller = await pumpViewer(tester);
    final pointer = TestPointer(11, PointerDeviceKind.mouse);
    pointer.hover(const Offset(400, 300));

    // plain wheel: scrolls the list, no zoom
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.zoom, 1);
    expect(controller.currentPage, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -300)));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.zoom, greaterThan(1));
  });

  testWidgets('jumpToPage scrolls to the requested page', (tester) async {
    final controller = await pumpViewer(tester);
    controller.jumpToPage(4);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.currentPage, 4);
  });
}
