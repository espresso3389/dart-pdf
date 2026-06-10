import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

void main() {
  Future<PdfViewerController> pumpViewer(WidgetTester tester,
      {int pages = 5,
      Uint8List? bytes,
      PdfActionHandler? onAction}) async {
    final controller = PdfViewerController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfViewer(
          document: PdfDocument.open(bytes ?? buildMultiPagePdf(pages)),
          controller: controller,
          onAction: onAction,
        ),
      ),
    ));
    await tester.pump();
    return controller;
  }

  // buildAnnotatedPdf link geometry, in view coordinates (800px viewport
  // over a 612pt page): centers of the annotation rects on page 1
  const annotScale = 800 / 612;
  Offset annotView(double x, double y) =>
      Offset(x * annotScale, (792 - y) * annotScale);

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

  testWidgets(
      'swapping documents under a Material AppBar does not dispatch '
      'scroll notifications during build', (tester) async {
    // Regression: didUpdateWidget (mid-build) used to call jumpTo(0) on a
    // document swap; jumpTo synchronously dispatches a ScrollNotification,
    // and the AppBar's scrolled-under listener reacts with setState —
    // illegally dirtying an ancestor during build.
    Widget app(PdfDocument document) => MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('viewer')),
            body: PdfViewer(document: document),
          ),
        );
    await tester.pumpWidget(app(PdfDocument.open(buildMultiPagePdf(3))));
    await tester.pump();
    await tester.drag(find.byType(PdfViewer), const Offset(0, -300));
    await tester.pump();

    await tester.pumpWidget(app(PdfDocument.open(buildMultiPagePdf(2))));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
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

  testWidgets('double-click and drag selects whole words', (tester) async {
    final controller = await pumpViewer(tester);
    const scale = 800 / 612;
    Offset view(double x, double y) => Offset(x * scale, (792 - y) * scale);
    // 'Page 1' at 24pt: 'Page' spans x 72..120, '1' spans x 132..144

    // first click
    await tester.tapAt(view(100, 720), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    // second press, held and dragged: anchor word 'Page', extend over '1'
    final gesture = await tester.startGesture(view(100, 720),
        kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(25, 0)); // pass the drag slop
    await tester.pump();
    await gesture.moveTo(view(140, 720));
    await tester.pump();
    expect(controller.selectedText, 'Page 1');

    // dragging back to the anchor word shrinks to just that word
    await gesture.moveTo(view(100, 720));
    await tester.pump();
    expect(controller.selectedText, 'Page');

    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(controller.selectedText, 'Page');
  });

  testWidgets('rapid mouse clicks on an overlay button all land',
      (tester) async {
    // Regression: a double-tap recognizer that accepted mice held every
    // click in the gesture arena for ~300ms and claimed the second of two
    // rapid clicks, so overlay buttons dropped taps.
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfViewer(
          document: PdfDocument.open(buildMultiPagePdf(2)),
          pageOverlayBuilder: (context, pageIndex, geometry) => [
            if (pageIndex == 0)
              Positioned.fromRect(
                rect: geometry.toViewRect(const PdfRect(72, 692, 172, 742)),
                child: TextButton(
                  key: const Key('overlay'),
                  onPressed: () => taps++,
                  child: const Text('go'),
                ),
              ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final center = tester.getCenter(find.byKey(const Key('overlay')));
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(center, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(taps, 4);
  });

  testWidgets('mouse clicks activate links without double-tap delay',
      (tester) async {
    final actions = <PdfAction>[];
    await pumpViewer(tester,
        bytes: buildAnnotatedPdf(), onAction: (a, _) => actions.add(a));

    await tester.tapAt(annotView(136, 652),
        kind: PointerDeviceKind.mouse); // URI link center
    await tester.pump(); // next frame — no disambiguation wait
    expect(actions, hasLength(1));
  });

  testWidgets('touch double-tap still toggles zoom', (tester) async {
    final controller = await pumpViewer(tester);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.zoom, greaterThan(1));
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

  testWidgets('tapping a URI link surfaces the action', (tester) async {
    final actions = <PdfAction>[];
    final annotations = <PdfAnnotation>[];
    await pumpViewer(tester, bytes: buildAnnotatedPdf(), onAction: (a, an) {
      actions.add(a);
      annotations.add(an);
    });

    await tester.tapAt(annotView(136, 652)); // URI link center
    // the tap fires once the competing double-tap recognizer times out
    await tester.pump(const Duration(milliseconds: 400));

    expect(actions, hasLength(1));
    expect((actions.single as PdfUriAction).uri, 'app://invoice/42');
    expect(annotations.single, isA<PdfLinkAnnotation>());
  });

  testWidgets('tapping a GoTo link navigates instead of surfacing it',
      (tester) async {
    final actions = <PdfAction>[];
    final controller = await pumpViewer(tester,
        bytes: buildAnnotatedPdf(), onAction: (a, _) => actions.add(a));

    await tester.tapAt(annotView(136, 612)); // GoTo link center
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(controller.currentPage, 2);
    expect(actions, isEmpty);
  });

  testWidgets('standard named page actions navigate internally',
      (tester) async {
    final actions = <PdfAction>[];
    final controller = await pumpViewer(tester,
        bytes: buildAnnotatedPdf(), onAction: (a, _) => actions.add(a));

    await tester.tapAt(annotView(350, 652)); // /Named /NextPage link
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(controller.currentPage, 1);
    expect(actions, isEmpty);
  });

  testWidgets('hidden annotations neither fire nor change the cursor',
      (tester) async {
    final actions = <PdfAction>[];
    await pumpViewer(tester,
        bytes: buildAnnotatedPdf(), onAction: (a, _) => actions.add(a));

    await tester.tapAt(annotView(350, 612)); // hidden URI link center
    await tester.pump(const Duration(milliseconds: 400));
    expect(actions, isEmpty);
  });

  testWidgets('hovering a link shows the click cursor', (tester) async {
    await pumpViewer(tester, bytes: buildAnnotatedPdf());

    MouseRegion region() => tester.widget<MouseRegion>(find
        .descendant(
            of: find.byType(PdfViewer), matching: find.byType(MouseRegion))
        .first);

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 9);
    await gesture.addPointer(location: annotView(400, 300)); // empty area
    addTearDown(gesture.removePointer);
    await tester.pump();
    expect(region().cursor, MouseCursor.defer);

    await gesture.moveTo(annotView(136, 652)); // over the URI link
    await tester.pump();
    expect(region().cursor, SystemMouseCursors.click);

    await gesture.moveTo(annotView(100, 725)); // over 'Page 1' text
    await tester.pump();
    expect(region().cursor, SystemMouseCursors.text);

    await gesture.moveTo(annotView(350, 612)); // hidden link: no cursor
    await tester.pump();
    expect(region().cursor, MouseCursor.defer);
  });

  testWidgets('jumpToPage scrolls to the requested page', (tester) async {
    final controller = await pumpViewer(tester);
    controller.jumpToPage(4);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(controller.currentPage, 4);
  });

  testWidgets('page overlays sit at PDF coordinates and stay interactive',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfViewer(
          document: PdfDocument.open(buildMultiPagePdf(2)),
          pageOverlayBuilder: (context, pageIndex, geometry) => [
            if (pageIndex == 0)
              Positioned.fromRect(
                rect: geometry.toViewRect(const PdfRect(72, 692, 172, 742)),
                child: TextButton(
                  key: const Key('overlay'),
                  onPressed: () => taps++,
                  child: const Text('go'),
                ),
              ),
          ],
        ),
      ),
    ));
    await tester.pump();

    // page 0 starts at scroll offset 0, so view space == page view space
    const scale = 800 / 612;
    final rect = tester.getRect(find.byKey(const Key('overlay')));
    expect(rect.left, moreOrLessEquals(72 * scale, epsilon: 0.1));
    expect(rect.top, moreOrLessEquals((792 - 742) * scale, epsilon: 0.1));
    expect(rect.width, moreOrLessEquals(100 * scale, epsilon: 0.1));
    expect(rect.height, moreOrLessEquals(50 * scale, epsilon: 0.1));

    // the overlay's own recognizer beats the viewer's tap/selection handling
    await tester.tap(find.byKey(const Key('overlay')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 1);

    // only page 0 got an overlay
    expect(find.byType(TextButton), findsOneWidget);
  });
}
