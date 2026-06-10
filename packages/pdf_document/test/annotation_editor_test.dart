import 'dart:convert';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  PdfDocument roundTrip(void Function(PdfEditor) edit) {
    final editor = PdfEditor(PdfDocument.open(buildClassicPdf()));
    edit(editor);
    return PdfDocument.open(editor.save());
  }

  String appearanceText(PdfDocument doc, PdfAnnotation annot) {
    final stream = annot.normalAppearance;
    expect(stream, isNotNull, reason: 'annotation must carry /AP /N');
    return latin1.decode(doc.cos.decodeStreamData(stream!));
  }

  test('highlight round-trips with quad points and a Multiply appearance',
      () {
    final doc = roundTrip((e) => e.addHighlight(
          0,
          const [PdfRect(72, 700, 200, 712), PdfRect(72, 686, 150, 698)],
          contents: 'important',
          author: 'Ben',
        ));
    final annots = doc.page(0).annotations;
    expect(annots, hasLength(1));
    final hl = annots.single;
    expect(hl.subtype, 'Highlight');
    expect(hl.rect, const PdfRect(72, 686, 200, 712));

    final quads = doc.cos.resolve(hl.dict['QuadPoints']) as CosArray;
    expect(quads.length, 16);

    final content = appearanceText(doc, hl);
    expect(content, contains('re'));
    expect(content, contains('f'));
    expect(content, contains('/GS0 gs'));

    final form = hl.normalAppearance!;
    final resources =
        doc.cos.resolve(form.dictionary['Resources']) as CosDictionary;
    final gstates = doc.cos.resolve(resources['ExtGState']) as CosDictionary;
    final gs0 = doc.cos.resolve(gstates['GS0']) as CosDictionary;
    expect((doc.cos.resolve(gs0['BM']) as CosName).value, 'Multiply');

    expect((doc.cos.resolve(hl.dict['Contents']) as CosString).text,
        'important');
    expect((doc.cos.resolve(hl.dict['T']) as CosString).text, 'Ben');
  });

  test('underline, strikeout, and squiggly carry quad points', () {
    final doc = roundTrip((e) {
      const quads = [PdfRect(72, 700, 200, 712)];
      e.addUnderline(0, quads);
      e.addStrikeOut(0, quads);
      e.addSquiggly(0, quads);
    });
    final subtypes = [for (final a in doc.page(0).annotations) a.subtype];
    expect(subtypes, ['Underline', 'StrikeOut', 'Squiggly']);
    for (final annot in doc.page(0).annotations) {
      expect(doc.cos.resolve(annot.dict['QuadPoints']), isA<CosArray>());
      expect(appearanceText(doc, annot), contains('S'));
    }
  });

  test('ink stores the stroke list and pads its rect by the line width', () {
    final doc = roundTrip((e) => e.addInk(
          0,
          [
            [(100, 100), (150, 130), (200, 100)],
            [(120, 90)],
          ],
          strokeWidth: 4,
        ));
    final ink = doc.page(0).annotations.single;
    expect(ink.subtype, 'Ink');
    // bounds (100,90)-(200,130) padded by width/2 + 1 = 3
    expect(ink.rect, const PdfRect(97, 87, 203, 133));

    final inkList = doc.cos.resolve(ink.dict['InkList']) as CosArray;
    expect(inkList.length, 2);
    expect((doc.cos.resolve(inkList[0]) as CosArray).length, 6);

    final content = appearanceText(doc, ink);
    expect(content, contains('1 J'));
    expect(content, contains('4 w'));
  });

  test('square and circle render stroke and fill', () {
    final doc = roundTrip((e) {
      e.addSquare(0, const PdfRect(100, 100, 200, 150),
          fillColor: 0x2040FF, opacity: 0.5);
      e.addCircle(0, const PdfRect(250, 100, 350, 150), strokeWidth: 3);
    });
    final annots = doc.page(0).annotations;
    expect([for (final a in annots) a.subtype], ['Square', 'Circle']);

    final square = appearanceText(doc, annots[0]);
    expect(square, contains('B')); // fill + stroke
    expect(doc.cos.resolve(annots[0].dict['IC']), isA<CosArray>());

    final circle = appearanceText(doc, annots[1]);
    expect(circle, contains('c')); // Bézier arcs
    expect(circle, contains('S'));
  });

  test('free text wraps to the rect and records /DA', () {
    final doc = roundTrip((e) => e.addFreeText(
          0,
          const PdfRect(72, 600, 240, 680),
          'The quick brown fox jumps over the lazy dog near the riverbank',
          fontSize: 12,
          fillColor: 0xFFFFE0,
          borderColor: 0x808080,
        ));
    final ft = doc.page(0).annotations.single;
    expect(ft.subtype, 'FreeText');

    final da = doc.cos.resolve(ft.dict['DA']) as CosString;
    expect(da.text, contains('/Helv 12 Tf'));

    final content = appearanceText(doc, ft);
    expect(content, contains('BT'));
    expect(content, contains('/Helv 12 Tf'));
    // 62 chars at 12pt Helvetica cannot fit one 168pt-wide line
    expect('T*'.allMatches(content).length, greaterThanOrEqualTo(2));
    expect(content, contains('W')); // clipped to the rect

    final form = ft.normalAppearance!;
    final resources =
        doc.cos.resolve(form.dictionary['Resources']) as CosDictionary;
    final fonts = doc.cos.resolve(resources['Font']) as CosDictionary;
    final helv = doc.cos.resolve(fonts['Helv']) as CosDictionary;
    expect((doc.cos.resolve(helv['BaseFont']) as CosName).value, 'Helvetica');
    expect((doc.cos.resolve(helv['Widths']) as CosArray).length, 95);
  });

  test('note builds a 20pt icon at the given top-left corner', () {
    final doc =
        roundTrip((e) => e.addNote(0, 500, 700, 'remember this', author: 'Ben'));
    final note = doc.page(0).annotations.single;
    expect(note.subtype, 'Text');
    expect(note.rect, const PdfRect(500, 680, 520, 700));
    expect((doc.cos.resolve(note.dict['Name']) as CosName).value, 'Comment');
    expect((doc.cos.resolve(note.dict['Contents']) as CosString).text,
        'remember this');
    expect(appearanceText(doc, note), contains('c')); // rounded corners
  });

  test('stamp centers bold text that fits the rect', () {
    final doc = roundTrip(
        (e) => e.addStamp(0, const PdfRect(100, 500, 260, 540), 'APPROVED'));
    final stamp = doc.page(0).annotations.single;
    expect(stamp.subtype, 'Stamp');

    final content = appearanceText(doc, stamp);
    expect(content, contains('/HelvB'));
    expect(content, contains('(APPROVED) Tj'));

    final form = stamp.normalAppearance!;
    final resources =
        doc.cos.resolve(form.dictionary['Resources']) as CosDictionary;
    final fonts = doc.cos.resolve(resources['Font']) as CosDictionary;
    final helvB = doc.cos.resolve(fonts['HelvB']) as CosDictionary;
    expect((doc.cos.resolve(helvB['BaseFont']) as CosName).value,
        'Helvetica-Bold');
  });

  test('annotations append to an existing /Annots array', () {
    final first = PdfEditor(PdfDocument.open(buildAnnotatedPdf()));
    final before =
        PdfDocument.open(buildAnnotatedPdf()).page(0).annotations.length;
    first.addNote(0, 500, 700, 'appended');
    final doc = PdfDocument.open(first.save());
    final annots = doc.page(0).annotations;
    expect(annots.length, before + 1);
    expect(annots.last.subtype, 'Text');
    // existing annotations are untouched
    expect(annots.first.subtype, 'Link');
  });

  test('appearance BBox equals the annotation rect (identity mapping)', () {
    final doc = roundTrip(
        (e) => e.addSquare(0, const PdfRect(10, 20, 110, 70)));
    final annot = doc.page(0).annotations.single;
    final bbox = pdfRectFrom(doc.cos, annot.normalAppearance!.dictionary['BBox']);
    expect(bbox, annot.rect);
  });

  test('the original bytes survive as a prefix (incremental update)', () {
    final original = buildClassicPdf();
    final editor = PdfEditor(PdfDocument.open(original))
      ..addNote(0, 500, 700, 'incremental');
    final saved = editor.save();
    expect(saved.length, greaterThan(original.length));
    expect(saved.sublist(0, original.length), original);
  });

  test('print flag is set so annotations survive printing', () {
    final doc = roundTrip(
        (e) => e.addHighlight(0, const [PdfRect(72, 700, 200, 712)]));
    expect(doc.page(0).annotations.single.flags & 4, 4);
  });
}
