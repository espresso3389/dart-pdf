import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  PdfAcroForm form() => PdfAcroForm.of(PdfDocument.open(buildAcroFormPdf()))!;

  test('a document without a form has no AcroForm', () {
    expect(PdfAcroForm.of(PdfDocument.open(buildClassicPdf())), isNull);
  });

  test('enumerates terminal fields depth-first with qualified names', () {
    final names = [for (final f in form().fields) f.name];
    expect(names, ['name', 'address', 'agree', 'color', 'size', 'serial']);
  });

  test('field types follow /FT and the discriminating /Ff bits', () {
    final f = form();
    expect(f.fieldNamed('name')!.type, PdfFieldType.text);
    expect(f.fieldNamed('address')!.type, PdfFieldType.text);
    expect(f.fieldNamed('agree')!.type, PdfFieldType.checkBox);
    expect(f.fieldNamed('color')!.type, PdfFieldType.radioGroup);
    expect(f.fieldNamed('size')!.type, PdfFieldType.comboBox);
  });

  test('flags surface read-only and multiline', () {
    final f = form();
    expect(f.fieldNamed('serial')!.isReadOnly, isTrue);
    expect(f.fieldNamed('name')!.isReadOnly, isFalse);
    expect(f.fieldNamed('address')!.isMultiline, isTrue);
    expect(f.fieldNamed('name')!.isMultiline, isFalse);
  });

  test('/DA falls back from the field to the form-wide default', () {
    final f = form();
    expect(f.fieldNamed('name')!.defaultAppearance, '/Helv 12 Tf 0 g');
    expect(f.fieldNamed('address')!.defaultAppearance, '/Helv 0 Tf 0 g');
    expect(f.defaultAppearance, '/Helv 0 Tf 0 g');
  });

  test('values read back as text', () {
    final f = form();
    expect(f.fieldNamed('name')!.value, 'prefilled');
    expect(f.fieldNamed('size')!.value, 'Medium');
    expect(f.fieldNamed('serial')!.value, 'A-1000');
    expect(f.fieldNamed('address')!.value, isNull);
    expect(f.fieldNamed('agree')!.value, 'Off');
    expect(f.fieldNamed('agree')!.isChecked, isFalse);
  });

  test('radio groups expose kid widgets and their on-states', () {
    final color = form().fieldNamed('color')!;
    expect(color.widgets, hasLength(2));
    expect(color.onStates, ['Red', 'Blue']);
    expect(color.widgetRect(0), const PdfRect(72, 500, 92, 520));
    expect(color.widgetRect(1), const PdfRect(120, 500, 140, 520));
  });

  test('merged fields are their own single widget', () {
    final name = form().fieldNamed('name')!;
    expect(name.widgets.single, same(name.dict));
    expect(name.widgetRect(0), const PdfRect(72, 700, 300, 724));
  });

  test('choice options pair export and display values', () {
    final size = form().fieldNamed('size')!;
    expect(size.options,
        [('Small', 'Small'), ('Medium', 'Medium'), ('L', 'Large')]);
    expect(size.quadding, 1);
  });

  test('inheritance walks the /Parent chain', () {
    final color = form().fieldNamed('color')!;
    // /FT and /Ff live on the parent field, not the kid widgets
    final kid = color.widgets.first;
    expect(kid.containsKey('FT'), isFalse);
    expect(color.fieldTypeName, 'Btn');
    expect(color.flags & PdfFormField.radioFlag, isNot(0));
  });

  test('NeedAppearances is surfaced', () {
    expect(form().needsAppearances, isTrue);
  });

  test('widgets parse as PdfWidgetAnnotation with field names', () {
    final doc = PdfDocument.open(buildAcroFormPdf());
    final widgets =
        doc.page(0).annotations.whereType<PdfWidgetAnnotation>().toList();
    expect(widgets, hasLength(7));
    expect(widgets.first.fieldName, 'name');
    expect(widgets.first.fieldType, 'Tx');
    final radio = widgets.firstWhere((w) => w.fieldName == 'color');
    expect(radio.fieldType, 'Btn');
  });

  test('an explicit null /V reads as empty, not as a crash', () {
    final doc = PdfDocument.open(buildAcroFormPdf());
    final field = PdfAcroForm.of(doc)!.fieldNamed('name')!;
    field.dict['V'] = CosNull.instance;
    expect(field.value, isNull);
  });
}
