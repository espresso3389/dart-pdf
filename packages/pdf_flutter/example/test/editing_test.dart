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
