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
    expect(size.width / size.height, moreOrLessEquals(612 / 792, epsilon: 1e-6));
  });
}
