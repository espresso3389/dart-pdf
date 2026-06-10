import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_viewer_example/main.dart';

void main() {
  // the app opens the interactive demo on launch
  Future<void> openDemo(WidgetTester tester) async {
    await tester.pumpWidget(const ViewerApp());
    await tester.pump();
  }

  // demo page is 612pt wide, shown 800px wide in the 800x600 test viewport
  const s = 800 / 612;

  /// Taps a point given in page 1's PDF coordinates.
  Future<void> tapOnPage(WidgetTester tester, double x, double y) async {
    final origin = tester.getTopLeft(find.byType(PdfViewer));
    await tester.tapAt(origin + Offset(x * s, (792 - y) * s));
    // single taps wait out the competing double-tap recognizer
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('PDF link increments the Flutter counter badge',
      (tester) async {
    await openDemo(tester);
    expect(find.text('0'), findsOneWidget); // the badge overlay

    await tapOnPage(tester, 176, 618); // "Increment the counter" link
    expect(find.text('1'), findsOneWidget);

    await tapOnPage(tester, 176, 618);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('PDF link shows an app message with its URI payload',
      (tester) async {
    await openDemo(tester);
    await tapOnPage(tester, 176, 558); // "Show a message" link
    await tester.pump(const Duration(milliseconds: 250)); // snackbar slides in
    expect(find.text('Hello from the PDF'), findsOneWidget);
  });

  testWidgets('GoTo link reaches the widgets page; overlays are live',
      (tester) async {
    await openDemo(tester);
    await tapOnPage(tester, 176, 498); // "Go to the widgets page" link
    // finish the scroll animation with plain pumps — the clock overlay's
    // periodic timer would keep pumpAndSettle from ever settling
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    // the counter control edits the same state the page-1 link increments
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1'), findsWidgets);

    // the note field accepts input above the page
    await tester.enterText(
        find.byType(TextField).last, 'typed over the PDF');
    expect(find.text('typed over the PDF'), findsOneWidget);

    // unmount so the clock's periodic timer is disposed before teardown
    await tester.pumpWidget(const SizedBox());
  });
}
