import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  group('annotated document', () {
    late PdfDocument doc;
    late List<PdfAnnotation> annots;

    setUp(() {
      doc = PdfDocument.open(buildAnnotatedPdf());
      annots = doc.page(0).annotations;
    });

    test('parses every /Annots entry with subtype and rect', () {
      expect(annots, hasLength(6));
      expect(annots[0], isA<PdfLinkAnnotation>());
      expect(annots[0].rect, const PdfRect(72, 640, 200, 664));
      expect(annots[3], isA<PdfWidgetAnnotation>());
      expect(annots[3].rect, const PdfRect(72, 520, 200, 544));
    });

    test('pages without /Annots have none', () {
      expect(doc.page(1).annotations, isEmpty);
    });

    test('URI action', () {
      final action = annots[0].action;
      expect(action, isA<PdfUriAction>());
      expect((action as PdfUriAction).uri, 'app://invoice/42');
    });

    test('GoTo action with an explicit destination', () {
      final action = annots[1].action;
      expect(action, isA<PdfGoToAction>());
      final destination = (action as PdfGoToAction).destination;
      expect(destination.pageIndex, 2);
      expect(destination.fit, 'XYZ');
      expect(destination.left, 0);
      expect(destination.top, 792);
      expect(destination.zoom, 0);
    });

    test('bare /Dest with a named destination resolves via the name tree',
        () {
      final action = annots[2].action;
      expect(action, isA<PdfGoToAction>());
      final destination = (action as PdfGoToAction).destination;
      expect(destination.pageIndex, 1);
      expect(destination.fit, 'FitH');
      expect(destination.top, 700);
      expect(destination.left, isNull);
    });

    test('widget push button: field info and JavaScript action', () {
      final widget = annots[3] as PdfWidgetAnnotation;
      expect(widget.fieldType, 'Btn');
      expect(widget.fieldName, 'actions.launch');
      final action = widget.action;
      expect(action, isA<PdfJavaScriptAction>());
      expect((action as PdfJavaScriptAction).script, 'app.alert(42)');
    });

    test('named action', () {
      final action = annots[4].action;
      expect(action, isA<PdfNamedAction>());
      expect((action as PdfNamedAction).name, 'NextPage');
    });

    test('hidden flag', () {
      expect(annots[5].isHidden, isTrue);
      expect(annots[0].isHidden, isFalse);
    });

    test('pageIndexOf maps page dictionaries to indices', () {
      expect(doc.pageIndexOf(doc.page(0).dict), 0);
      expect(doc.pageIndexOf(doc.page(2).dict), 2);
      expect(doc.pageIndexOf(doc.catalog), -1);
    });

    test('annotations without /AP have no appearance', () {
      expect(annots[0].normalAppearance, isNull);
    });
  });

  group('appearance streams', () {
    late PdfDocument doc;
    late List<PdfAnnotation> annots;

    setUp(() {
      doc = PdfDocument.open(buildAppearanceAnnotationsPdf());
      annots = doc.page(0).annotations;
    });

    String decoded(PdfAnnotation annotation) => String.fromCharCodes(
        doc.cos.decodeStreamData(annotation.normalAppearance!));

    test('/AP /N resolves to the form stream', () {
      expect(decoded(annots[0]), contains('0 1 0 rg'));
    });

    test('/AS picks the state out of an /N subdictionary', () {
      expect(annots[2], isA<PdfWidgetAnnotation>());
      expect(decoded(annots[2]), contains('0.5 g'));
    });

    test('hidden flag parses alongside the appearance', () {
      expect(annots[3].isHidden, isTrue);
      expect(annots[3].normalAppearance, isNotNull);
    });
  });
}
