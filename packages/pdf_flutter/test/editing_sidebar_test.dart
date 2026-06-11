import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

void main() {
  Future<void> pumpSidebar(WidgetTester tester, PdfEditingController editing,
      PdfViewerController viewer) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          Expanded(
            child: ListenableBuilder(
              listenable: editing,
              builder: (context, _) => PdfViewer(
                initialFit: PdfViewerFit.width,
                document: editing.document,
                controller: viewer,
                editing: editing,
              ),
            ),
          ),
          PdfAnnotationSidebar(controller: editing, viewerController: viewer),
        ]),
      ),
    ));
    await tester.pump();
  }

  testWidgets('annotations carry the author and the sidebar shows it',
      (tester) async {
    final editing = PdfEditingController(buildMultiPagePdf(1))
      ..author = 'Ben'
      ..addNote(0, 100, 700, 'first note');
    final viewer = PdfViewerController();
    addTearDown(editing.dispose);
    addTearDown(viewer.dispose);

    expect(editing.document.page(0).annotations.single.author, 'Ben');

    await pumpSidebar(tester, editing, viewer);
    expect(find.text('Ben — first note'), findsOneWidget);
  });

  testWidgets('long-press multi-select deletes the checked set as one undo',
      (tester) async {
    final editing = PdfEditingController(buildMultiPagePdf(2))
      ..addNote(0, 100, 700, 'first note')
      ..addRectangle(0, const PdfRect(100, 100, 200, 150))
      ..addRectangle(1, const PdfRect(100, 100, 200, 150));
    final viewer = PdfViewerController();
    addTearDown(editing.dispose);
    addTearDown(viewer.dispose);
    await pumpSidebar(tester, editing, viewer);

    await tester.longPress(find.text('Note'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));

    // check the page-1 square too (the first of the two Square tiles)
    await tester.tap(find.text('Square').first);
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete selected'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(editing.document.page(0).annotations, isEmpty);
    expect(editing.document.page(1).annotations, hasLength(1));
    // the revision swap leaves selection mode
    expect(find.text('2 selected'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);

    // both went in one revision: a single undo restores them together
    editing.undo();
    await tester.pump();
    expect(editing.document.page(0).annotations, hasLength(2));
  });

  testWidgets('tapping a tile zooms the viewer to the annotation',
      (tester) async {
    // mid-page, so framing it needs no clamping at the document edges
    final editing = PdfEditingController(buildMultiPagePdf(1))
      ..addRectangle(0, const PdfRect(250, 350, 400, 450));
    final viewer = PdfViewerController();
    addTearDown(editing.dispose);
    addTearDown(viewer.dispose);
    await pumpSidebar(tester, editing, viewer);
    expect(viewer.zoom, 1);

    await tester.tap(find.text('Square'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // the viewer is 520x600 over a 612pt page: the 150x100pt rect at 40%
    // viewport fill wants scale 0.4 * 520 / (150 * 520/612) ≈ 1.63
    expect(viewer.zoom, closeTo(1.63, 0.05));
    expect(editing.selectedAnnotation?.subtype, 'Square');

    // the rect (fractions of 612x792, y-down) is centered and contained
    final region = viewer.visiblePageRegion(0)!;
    expect(region.center.dx, closeTo(325 / 612, 0.02));
    expect(region.center.dy, closeTo((792 - 400) / 792, 0.02));
    expect(region.left, lessThan(250 / 612));
    expect(region.right, greaterThan(400 / 612));
    expect(region.top, lessThan((792 - 450) / 792));
    expect(region.bottom, greaterThan((792 - 350) / 792));
  });
}
