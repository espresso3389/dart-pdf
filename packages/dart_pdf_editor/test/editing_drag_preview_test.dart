import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:dart_pdf_editor/src/editing/editing_overlay.dart';
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

void main() {
  test(
      'renderAnnotationPicture draws just the appearance, transparent '
      'elsewhere', () async {
    final editing = PdfEditingController(buildMultiPagePdf(1))
      ..color = const Color(0xFFFF0000)
      ..addRectangle(0, const PdfRect(100, 650, 250, 750));
    final page = editing.document.page(0);
    final annotation = page.annotations.single;

    final picture =
        await PdfPageRenderer.renderAnnotationPicture(page, annotation);
    expect(picture, isNotNull);
    final image = await PdfPageRenderer.rasterize(
        picture!, PdfPageRenderer.pageSize(page), 1);
    final data = (await image.toByteData())!;

    // page raster space is y-down: page (100, 700) → raster (100, 92).
    // the square's left border is stroked in the annotation color
    final (r, g, b, a) = pixelAt(data, image.width, 100, 92);
    expect(a, greaterThan(200));
    expect(r, greaterThan(200));
    expect(g, lessThan(80));
    expect(b, lessThan(80));

    // outside the annotation the picture stays fully transparent
    final (_, _, _, a2) = pixelAt(data, image.width, 400, 92);
    expect(a2, 0);
    image.dispose();
    picture.dispose();
  });

  test('paintAnnotationDragPreview maps the picture onto the target rect',
      () async {
    // a "page-space" appearance: a solid red square at points 10..20
    final appearance = ui.PictureRecorder();
    Canvas(appearance).drawRect(const Rect.fromLTRB(10, 10, 20, 20),
        Paint()..color = const Color(0xFFFF0000));
    final picture = appearance.endRecording();

    // at 2 px/pt the square rests at view rect 20..40; the drag both
    // moves it and doubles its size
    const from = Rect.fromLTRB(20, 20, 40, 40);
    const to = Rect.fromLTRB(120, 60, 160, 100);
    final recorder = ui.PictureRecorder();
    paintAnnotationDragPreview(Canvas(recorder),
        picture: picture, from: from, to: to, scale: 2);
    final image = await recorder.endRecording().toImage(200, 150);
    final data = (await image.toByteData())!;

    // the center of `to` carries the square at ~75% opacity
    // (premultiplied, so the red channel rides at ~alpha)
    final (r, _, _, a) = pixelAt(data, image.width, 140, 80);
    expect(a, closeTo(191, 25));
    expect(r, closeTo(191, 25));

    // the resting position is untouched — the preview moved, the
    // original spot stays for the page below to show through
    final (_, _, _, a2) = pixelAt(data, image.width, 30, 30);
    expect(a2, 0);
    image.dispose();
    picture.dispose();
  });

  group('live preview in the viewer', () {
    // 800px viewport over a 612pt page
    const scale = 800 / 612;
    Offset view(double x, double y) => Offset(x * scale, (792 - y) * scale);

    testWidgets('a move drag shows the annotation at the dragged position',
        (tester) async {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      final viewer = PdfViewerController();
      addTearDown(editing.dispose);
      addTearDown(viewer.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
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
        ),
      ));
      await tester.pump();

      editing
        ..color = const Color(0xFFFF0000)
        ..addRectangle(0, const PdfRect(100, 650, 250, 750))
        ..tool = PdfEditTool.select;
      await tester.pump();
      await tester.tapAt(view(175, 700));
      // double-tap hold, selection, and the ghost render all settle here
      await tester.pumpAndSettle(const Duration(milliseconds: 350));
      expect(editing.selectedAnnotation, isNotNull);

      // drag the annotation toward the lower right and hold mid-drag
      final gesture = await tester.startGesture(view(175, 700));
      await gesture.moveTo(view(255, 550));
      await gesture.moveTo(view(335, 400));
      await tester.pump();

      final image = await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        return render.toImage();
      });
      final data = (await tester.runAsync(image!.toByteData))!;

      // the square's red left border previews at the dragged position:
      // original edge midpoint (100, 700) shifted by the drag delta
      final delta = view(335, 400) - view(175, 700);
      final edge = view(100, 700) + delta;
      var sawRed = false;
      for (var dx = -2; dx <= 2 && !sawRed; dx++) {
        final (r, g, b, _) =
            pixelAt(data, image.width, edge.dx.round() + dx, edge.dy.round());
        sawRed = r > 180 && g < 140 && b < 140;
      }
      expect(sawRed, isTrue,
          reason: 'the dragged annotation should preview its appearance');
      image.dispose();

      // releasing commits the move where the preview showed it
      await gesture.up();
      await tester.pumpAndSettle(const Duration(milliseconds: 350));
      final rect = editing.selectedAnnotation!.rect;
      expect(rect.left, closeTo(260, 2));
      expect(rect.top, closeTo(450, 2));
    });
  });
}
