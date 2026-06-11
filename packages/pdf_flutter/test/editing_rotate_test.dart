import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_flutter/src/editing/editing_overlay.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

(int r, int g, int b, int a) pixelAt(ByteData data, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return (
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
    data.getUint8(i + 3),
  );
}

double matrixEntry(PdfDocument doc, PdfAnnotation annotation, int i) {
  final matrix = doc.cos
      .resolve(annotation.normalAppearance!.dictionary['Matrix']) as CosArray;
  final n = doc.cos.resolve(matrix[i]);
  return n is CosInteger ? n.value.toDouble() : (n as CosReal).value;
}

void main() {
  test('rotateSelected(90) turns the square: rect, matrix, and pixels',
      () async {
    final editing = PdfEditingController(buildMultiPagePdf(1))
      ..color = const Color(0xFFFF0000)
      ..addRectangle(0, const PdfRect(100, 650, 250, 750))
      ..selectAnnotation(0, 0);
    expect(editing.canRotateSelected, isTrue);
    editing.rotateSelected(90);

    // 150×100 about center (175,700) → 100×150, same center
    final annotation = editing.document.page(0).annotations.single;
    final rect = annotation.rect;
    expect(rect.left, closeTo(125, 1e-6));
    expect(rect.bottom, closeTo(625, 1e-6));
    expect(rect.right, closeTo(225, 1e-6));
    expect(rect.top, closeTo(775, 1e-6));
    // +90° is counterclockwise in page space: b = 1
    expect(matrixEntry(editing.document, annotation, 1), closeTo(1, 1e-9));

    // and it renders rotated: the stroked border now runs along the new
    // top edge (page y=775), while the old left edge (x=100) is empty
    final page = editing.document.page(0);
    final picture =
        await PdfPageRenderer.renderAnnotationPicture(page, annotation);
    final image = await PdfPageRenderer.rasterize(
        picture!, PdfPageRenderer.pageSize(page), 1);
    final data = (await image.toByteData())!;
    final (r, g, b, a) = pixelAt(data, image.width, 175, 792 - 775);
    expect(a, greaterThan(200));
    expect(r, greaterThan(200));
    expect(g, lessThan(80));
    expect(b, lessThan(80));
    final (_, _, _, a2) = pixelAt(data, image.width, 100, 792 - 700);
    expect(a2, 0);
    image.dispose();
    picture.dispose();
  });

  test('paintAnnotationDragPreview spins the picture about the rect center',
      () async {
    // an asymmetric "appearance": only the left half of pts 10..20 is red
    final appearance = ui.PictureRecorder();
    Canvas(appearance).drawRect(const Rect.fromLTRB(10, 10, 15, 20),
        Paint()..color = const Color(0xFFFF0000));
    final picture = appearance.endRecording();

    // resting at view 20..40 (2 px/pt); a quarter turn clockwise should
    // carry the left half onto the top half
    const rect = Rect.fromLTRB(20, 20, 40, 40);
    final recorder = ui.PictureRecorder();
    paintAnnotationDragPreview(Canvas(recorder),
        picture: picture,
        from: rect,
        to: rect,
        scale: 2,
        rotation: math.pi / 2);
    final image = await recorder.endRecording().toImage(60, 60);
    final data = (await image.toByteData())!;

    // top-center carries the rotated half at ~75% premultiplied alpha
    final (r, _, _, a) = pixelAt(data, image.width, 30, 23);
    expect(a, closeTo(191, 25));
    expect(r, closeTo(191, 25));

    // the bottom-left quadrant (red before rotating) is now empty
    final (_, _, _, a2) = pixelAt(data, image.width, 23, 37);
    expect(a2, 0);
    image.dispose();
    picture.dispose();
  });

  group('rotate handle in the viewer', () {
    // 800px viewport over a 612pt page
    const scale = 800 / 612;
    Offset view(double x, double y) => Offset(x * scale, (792 - y) * scale);

    testWidgets('dragging the handle a quarter turn clockwise commits -90°',
        (tester) async {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      final viewer = PdfViewerController();
      addTearDown(editing.dispose);
      addTearDown(viewer.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: editing,
            builder: (context, _) => PdfViewer(
              initialFit: PdfViewerFit.width,
              document: editing.document,
              controller: viewer,
              editing: editing,
            ),
          ),
        ),
      ));
      await tester.pump();

      editing
        ..color = const Color(0xFFFF0000)
        ..addRectangle(0, const PdfRect(100, 650, 250, 750))
        ..tool = PdfEditTool.select;
      await tester.pump();
      await tester.tapAt(view(175, 700));
      await tester.pumpAndSettle(const Duration(milliseconds: 350));
      expect(editing.selectedAnnotation, isNotNull);
      expect(editing.canRotateSelected, isTrue);

      // the knob floats 22px above the selection's top-center
      final handle = view(175, 750) - const Offset(0, 22);
      final center = view(175, 700);
      final gesture = await tester.startGesture(handle);
      // sweep from straight-up to pointing-right: +90° in view space
      await gesture.moveTo(center + const Offset(100, -100));
      await gesture.moveTo(center + const Offset(140, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle(const Duration(milliseconds: 350));

      // clockwise on screen is -90° in page space: b = -1, and the
      // 150×100 rect becomes 100×150 about the same center
      final annotation = editing.selectedAnnotation!;
      expect(matrixEntry(editing.document, annotation, 1), closeTo(-1, 1e-9));
      final rect = annotation.rect;
      expect(rect.left, closeTo(125, 1e-6));
      expect(rect.bottom, closeTo(625, 1e-6));
      expect(rect.right, closeTo(225, 1e-6));
      expect(rect.top, closeTo(775, 1e-6));
    });
  });
}
