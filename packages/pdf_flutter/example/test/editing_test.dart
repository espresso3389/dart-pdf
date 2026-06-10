import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_viewer_example/main.dart';

void main() {
  Future<void> openDemo(WidgetTester tester) async {
    await tester.pumpWidget(const ViewerApp());
    await tester.pump();
  }

  Future<void> snackbarShows(WidgetTester tester, String text) async {
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(text), findsOneWidget);
  }

  testWidgets('rectangle tool drags out a square annotation',
      (tester) async {
    await openDemo(tester);

    await tester.tap(find.byTooltip('Rectangle'));
    await tester.pump();

    final origin = tester.getTopLeft(find.byType(PdfViewer));
    final gesture =
        await tester.startGesture(origin + const Offset(200, 150));
    await gesture.moveBy(const Offset(30, 20)); // past the drag slop
    await tester.pump();
    await gesture.moveBy(const Offset(90, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    await snackbarShows(tester, 'Rectangle added');
  });

  testWidgets('note tool prompts for text and places a note',
      (tester) async {
    await openDemo(tester);

    await tester.tap(find.byTooltip('Note'));
    await tester.pump();

    final origin = tester.getTopLeft(find.byType(PdfViewer));
    await tester.tapAt(origin + const Offset(300, 200));
    // single taps wait out the viewer's competing double-tap recognizer
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('New note'), findsOneWidget); // the dialog
    await tester.enterText(find.byType(TextField).last, 'A test note');
    await tester.tap(find.text('Add'));
    await tester.pump();

    await snackbarShows(tester, 'Note added');
  });

  /// Adds a rectangle annotation at (200,150)-(320,230) in view space and
  /// returns its center, ready to be selected.
  Future<Offset> addRectangle(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Rectangle'));
    await tester.pump();
    final origin = tester.getTopLeft(find.byType(PdfViewer));
    final gesture =
        await tester.startGesture(origin + const Offset(200, 150));
    await gesture.moveBy(const Offset(30, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(90, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400)); // snackbar + reload
    return origin + const Offset(260, 190);
  }

  Future<void> selectAt(WidgetTester tester, Offset center) async {
    await tester.tap(find.byTooltip('Select annotation'));
    await tester.pump();
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('select tool picks an annotation and deletes it',
      (tester) async {
    await openDemo(tester);
    final center = await addRectangle(tester);
    await selectAt(tester, center);

    final delete = find.byTooltip('Delete annotation');
    expect(delete, findsOneWidget); // selection chrome buttons appeared
    await tester.tap(delete);
    await tester.pump();

    await snackbarShows(tester, 'Annotation deleted');
    // tapping the same spot again selects nothing
    await tester.pump(const Duration(seconds: 2)); // let the snackbar pass
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Delete annotation'), findsNothing);
  });

  testWidgets('dragging a selected annotation moves it', (tester) async {
    await openDemo(tester);
    final center = await addRectangle(tester);
    await selectAt(tester, center);
    expect(find.byTooltip('Delete annotation'), findsOneWidget);

    // pass the slop in a small step so the pan's accepted start point is
    // still inside the annotation, then move for real
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(19, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 15));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 15));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    await snackbarShows(tester, 'Annotation moved');
    // the selection followed the annotation: its shifted center hits it
    await tester.pump(const Duration(seconds: 2));
    await tester.tapAt(center + const Offset(40, 30));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Delete annotation'), findsOneWidget);
  });

  testWidgets('note text can be edited through the selection',
      (tester) async {
    await openDemo(tester);

    // place a note
    await tester.tap(find.byTooltip('Note'));
    await tester.pump();
    final origin = tester.getTopLeft(find.byType(PdfViewer));
    await tester.tapAt(origin + const Offset(300, 200));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField).last, 'first draft');
    await tester.tap(find.text('Add'));
    await tester.pump(const Duration(milliseconds: 400));

    // notes hang their 20pt icon down-right of the tap point
    await selectAt(tester, origin + const Offset(310, 210));
    final edit = find.byTooltip('Edit annotation text');
    expect(edit, findsOneWidget);
    await tester.tap(edit);
    await tester.pump();

    expect(find.widgetWithText(TextField, 'first draft'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'second draft');
    await tester.tap(find.text('Add'));
    await tester.pump();

    await snackbarShows(tester, 'Annotation updated');
  });

  testWidgets('draw tool collects strokes and the check commits them',
      (tester) async {
    await openDemo(tester);

    await tester.tap(find.byTooltip('Draw'));
    await tester.pump();

    final origin = tester.getTopLeft(find.byType(PdfViewer));
    final gesture =
        await tester.startGesture(origin + const Offset(150, 250));
    await gesture.moveBy(const Offset(25, 10));
    await tester.pump();
    await gesture.moveBy(const Offset(40, -20));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // a pending stroke surfaces the commit/discard buttons
    final commit = find.byTooltip('Add ink annotation');
    expect(commit, findsOneWidget);
    await tester.tap(commit);
    await tester.pump();

    await snackbarShows(tester, 'Ink annotation added');
  });
}
