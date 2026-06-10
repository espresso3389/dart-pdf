import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';

void main() {
  group('PdfEditingController', () {
    test('apply commits a revision; undo and redo walk the prefix stack',
        () {
      final editing = PdfEditingController(buildMultiPagePdf(2));
      final originalLength = editing.bytes.length;
      expect(editing.isModified, isFalse);
      expect(editing.canUndo, isFalse);

      editing.addRectangle(0, const PdfRect(100, 100, 200, 150));
      expect(editing.document.page(0).annotations, hasLength(1));
      expect(editing.isModified, isTrue);
      final oneEditLength = editing.bytes.length;
      expect(oneEditLength, greaterThan(originalLength));

      editing.addEllipse(0, const PdfRect(250, 100, 350, 150));
      expect(editing.document.page(0).annotations, hasLength(2));
      // incremental updates: each revision extends the previous one
      expect(editing.bytes.length, greaterThan(oneEditLength));
      expect(editing.bytes.sublist(0, originalLength),
          buildMultiPagePdf(2));

      editing.undo();
      expect(editing.document.page(0).annotations, hasLength(1));
      expect(editing.bytes.length, oneEditLength);
      expect(editing.canRedo, isTrue);

      editing.undo();
      expect(editing.document.page(0).annotations, isEmpty);
      expect(editing.isModified, isFalse);
      expect(editing.canUndo, isFalse);

      editing.redo();
      editing.redo();
      expect(editing.document.page(0).annotations, hasLength(2));
      expect(editing.canRedo, isFalse);
    });

    test('an edit after undo discards the redoable revisions', () {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      editing.addRectangle(0, const PdfRect(100, 100, 200, 150));
      editing.undo();
      editing.addEllipse(0, const PdfRect(250, 100, 350, 150));
      expect(editing.canRedo, isFalse);
      expect(editing.document.page(0).annotations.single.subtype, 'Circle');
    });

    test('apply with no staged changes is not a revision', () {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      expect(editing.apply((_) {}), isFalse);
      expect(editing.isModified, isFalse);
    });

    test('ink strokes buffer until finishInk commits one Ink annotation',
        () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..addInkStroke(0, [(100, 100), (150, 130), (200, 100)])
        ..addInkStroke(0, [(120, 90), (140, 95)]);
      expect(editing.hasPendingInk, isTrue);
      expect(editing.strokesOn(0), hasLength(2));
      expect(editing.isModified, isFalse, reason: 'nothing committed yet');

      editing.finishInk();
      expect(editing.hasPendingInk, isFalse);
      expect(editing.strokesOn(0), isEmpty);
      final ink = editing.document.page(0).annotations.single;
      expect(ink.subtype, 'Ink');
    });

    test('discardInk throws the buffer away without a revision', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..addInkStroke(0, [(100, 100), (150, 130)])
        ..discardInk();
      expect(editing.hasPendingInk, isFalse);
      expect(editing.isModified, isFalse);
    });

    test('leaving the ink tool commits the pending drawing', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..tool = PdfEditTool.ink
        ..addInkStroke(0, [(100, 100), (150, 130)])
        ..tool = PdfEditTool.select;
      expect(editing.hasPendingInk, isFalse);
      expect(editing.document.page(0).annotations.single.subtype, 'Ink');
    });

    test('addMarkup highlights the given quads', () {
      final editing = PdfEditingController(buildMultiPagePdf(2))
        ..addMarkup(PdfMarkupKind.highlight, {
          0: const [PdfRect(72, 700, 200, 712)],
          1: const [PdfRect(72, 650, 180, 662)],
        });
      expect(editing.document.page(0).annotations.single.subtype, 'Highlight');
      expect(editing.document.page(1).annotations.single.subtype, 'Highlight');
    });

    test('select, move, resize, and delete an annotation', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..addRectangle(0, const PdfRect(100, 100, 200, 150))
        ..tool = PdfEditTool.select;

      expect(editing.selectAnnotationAt(0, 150, 125), isTrue);
      expect(editing.selectedAnnotation!.subtype, 'Square');
      expect(editing.canResizeSelected, isTrue);

      editing.moveSelected(10, 20);
      // the annotation keeps its /Annots slot, so the selection survives
      expect(editing.selectedAnnotation, isNotNull);
      expect(editing.selectedAnnotation!.rect,
          const PdfRect(110, 120, 210, 170));

      editing.resizeSelected(const PdfRect(110, 120, 310, 270));
      expect(editing.selectedAnnotation!.rect,
          const PdfRect(110, 120, 310, 270));

      editing.deleteSelected();
      expect(editing.selectedAnnotation, isNull);
      expect(editing.document.page(0).annotations, isEmpty);

      expect(editing.selectAnnotationAt(0, 150, 125), isFalse);
    });

    test('links and widgets are not selectable', () {
      final editing = PdfEditingController(buildAnnotatedPdf());
      // dead center of the URI link at (72,640)-(200,664) on page 0
      expect(editing.selectAnnotationAt(0, 136, 652), isFalse);
    });

    test('setSelectedText rewrites a note in place', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..addNote(0, 100, 700, 'hello')
        ..tool = PdfEditTool.select;
      expect(editing.selectAnnotationAt(0, 110, 690), isTrue);
      expect(editing.canEditSelectedText, isTrue);
      expect(editing.selectedText, 'hello');

      editing.setSelectedText('world');
      final note = editing.document.page(0).annotations.single;
      expect(note.subtype, 'Text');
      expect(note.contents, 'world');
    });

    test('undo and redo clear the annotation selection', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..addRectangle(0, const PdfRect(100, 100, 200, 150))
        ..tool = PdfEditTool.select;
      editing.selectAnnotationAt(0, 150, 125);
      editing.undo();
      expect(editing.selectedAnnotation, isNull);
    });
  });

  group('editing in the viewer', () {
    // 800px viewport over a 612pt page
    const scale = 800 / 612;
    Offset view(double x, double y) => Offset(x * scale, (792 - y) * scale);

    /// Drags in two steps: a recognizer that accepts on a single large
    /// move never delivers a pan update for it.
    Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
      final gesture = await tester.startGesture(from);
      await gesture.moveTo(Offset.lerp(from, to, 0.5)!);
      await gesture.moveTo(to);
      await gesture.up();
      await tester.pump();
    }

    /// Flushes the viewer's debounced settle timers (200/250ms), which a
    /// document-swap relayout can arm.
    Future<void> settle(WidgetTester tester) =>
        tester.pumpAndSettle(const Duration(milliseconds: 300));

    Future<(PdfEditingController, PdfViewerController)> pumpEditor(
        WidgetTester tester,
        {int pages = 3}) async {
      final editing = PdfEditingController(buildMultiPagePdf(pages));
      final viewer = PdfViewerController();
      addTearDown(editing.dispose);
      addTearDown(viewer.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: editing,
            builder: (context, _) => PdfViewer(
              document: editing.document,
              controller: viewer,
              editing: editing,
            ),
          ),
        ),
      ));
      await tester.pump();
      return (editing, viewer);
    }

    testWidgets('dragging with the rectangle tool adds a Square',
        (tester) async {
      final (editing, _) = await pumpEditor(tester);
      editing.tool = PdfEditTool.rectangle;
      await tester.pump();

      await drag(tester, view(100, 700), view(250, 600));

      final annotation = editing.document.page(0).annotations.single;
      expect(annotation.subtype, 'Square');
      expect(annotation.rect.width, greaterThan(100));
      expect(annotation.rect.height, greaterThan(50));
      expect(editing.document.page(1).annotations, isEmpty);
      await settle(tester);
    });

    testWidgets('the ink tool buffers strokes drawn on the page',
        (tester) async {
      final (editing, _) = await pumpEditor(tester);
      editing.tool = PdfEditTool.ink;
      await tester.pump();

      final gesture = await tester.startGesture(view(100, 700));
      await gesture.moveTo(view(150, 680));
      await gesture.moveTo(view(200, 700));
      await gesture.up();
      await tester.pump();

      expect(editing.strokesOn(0), hasLength(1));
      expect(editing.isModified, isFalse);
      editing.finishInk();
      expect(editing.document.page(0).annotations.single.subtype, 'Ink');
      await settle(tester);
    });

    testWidgets('tap selects, delete key removes', (tester) async {
      final (editing, _) = await pumpEditor(tester);
      editing
        ..addRectangle(0, const PdfRect(100, 650, 250, 750))
        ..tool = PdfEditTool.select;
      await tester.pump();

      await tester.tapAt(view(175, 700));
      // the viewer's touch double-tap recognizer holds taps for 300ms
      await settle(tester);
      expect(editing.selectedAnnotation?.subtype, 'Square');

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(editing.document.page(0).annotations, isEmpty);
      await settle(tester);
    });

    testWidgets('dragging a corner handle resizes the selection',
        (tester) async {
      final (editing, _) = await pumpEditor(tester);
      editing
        ..addRectangle(0, const PdfRect(100, 650, 250, 750))
        ..tool = PdfEditTool.select;
      await tester.pump();
      await tester.tapAt(view(175, 700));
      await settle(tester);
      expect(editing.selectedAnnotation, isNotNull);

      // bottom-right handle in view space = page (right, bottom)
      await drag(tester, view(250, 650), view(290, 620));

      final rect = editing.selectedAnnotation!.rect;
      expect(rect.right, greaterThan(270));
      expect(rect.bottom, lessThan(640));
      expect(rect.left, closeTo(100, 1));
      expect(rect.top, closeTo(750, 1));
      await settle(tester);
    });

    testWidgets('ctrl+Z undoes, ctrl+shift+Z redoes', (tester) async {
      final (editing, _) = await pumpEditor(tester);
      editing.addRectangle(0, const PdfRect(100, 650, 250, 750));
      await tester.pump();

      // focus the viewer the way a user would: click it
      await tester.tapAt(view(400, 400));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(editing.document.page(0).annotations, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(editing.document.page(0).annotations, hasLength(1));
      await settle(tester);
    });

    testWidgets('an edit keeps the scroll position', (tester) async {
      final (editing, viewer) = await pumpEditor(tester, pages: 5);
      // don't await: the returned future completes only as frames pump
      unawaited(viewer.jumpToPage(2));
      await settle(tester);
      expect(viewer.currentPage, 2);

      editing.addRectangle(2, const PdfRect(100, 650, 250, 750));
      await settle(tester);
      expect(viewer.currentPage, 2,
          reason: 'a same-geometry revision swap must not reset the scroll');
    });

    testWidgets('escape backs out: selection, then tool', (tester) async {
      final (editing, _) = await pumpEditor(tester);
      editing
        ..addRectangle(0, const PdfRect(100, 650, 250, 750))
        ..tool = PdfEditTool.select;
      await tester.pump();
      await tester.tapAt(view(175, 700));
      await settle(tester);
      expect(editing.selectedAnnotation, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(editing.selectedAnnotation, isNull);
      expect(editing.tool, PdfEditTool.select);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(editing.tool, isNull);
      await settle(tester);
    });

    testWidgets('the toolbar arms tools and undoes', (tester) async {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      final viewer = PdfViewerController();
      addTearDown(editing.dispose);
      addTearDown(viewer.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: editing,
            builder: (context, _) => PdfViewer(
              document: editing.document,
              controller: viewer,
              editing: editing,
            ),
          ),
          bottomNavigationBar: PdfEditingToolbar(
            controller: editing,
            viewerController: viewer,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byTooltip('Rectangle'));
      await tester.pump();
      expect(editing.tool, PdfEditTool.rectangle);
      await tester.tap(find.byTooltip('Rectangle'));
      await tester.pump();
      expect(editing.tool, isNull);

      editing.addRectangle(0, const PdfRect(100, 650, 250, 750));
      await tester.pump();
      await tester.tap(find.byTooltip('Undo (⌘Z)'));
      await tester.pump();
      expect(editing.document.page(0).annotations, isEmpty);
      await settle(tester);
    });
  });
}
