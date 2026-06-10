import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

final key = RsaPrivateKey.fromPem(testSignerKeyPem);
final cert = pemBytes(testSignerCertPem);
final signedAt = DateTime.utc(2026, 6, 10, 12, 0, 0);

Uint8List signedFixture() {
  final editor = PdfEditor(PdfDocument.open(buildMultiPagePdf(2)));
  return editor.saveSigned(
    privateKey: key,
    certificates: [cert],
    reason: 'Approval',
    location: 'Melbourne',
    signingTime: signedAt,
  );
}

/// A one-page PDF with an AcroForm holding one empty signature field
/// "ApproverSig" whose widget sits on the page.
Uint8List buildEmptySigFieldPdf() {
  const content = 'BT /F1 24 Tf 72 720 Td (Sign here) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] '
        '/SigFlags 3 >> >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /FT /Sig /T (ApproverSig) /Type /Annot /Subtype /Widget '
        '/Rect [100 100 300 150] /F 4 /P 3 0 R >>',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefOffset = buffer.length;
  buffer
    ..write('xref\n0 ${objects.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer
    ..write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n')
    ..write('startxref\n$xrefOffset\n%%EOF\n');
  return ascii(buffer.toString());
}

void main() {
  group('signing', () {
    test('a signed document validates as intact and whole', () {
      final doc = PdfDocument.open(signedFixture());
      final signatures = PdfSignature.of(doc);
      expect(signatures, hasLength(1));
      final signature = signatures.single;
      expect(signature.field.name, 'Signature1');
      expect(signature.signerName, 'Dart PDF Test Signer');
      expect(signature.reason, 'Approval');
      expect(signature.location, 'Melbourne');
      expect(signature.subFilter, 'adbe.pkcs7.detached');
      expect(signature.signingTime, signedAt);

      final result = signature.validate();
      expect(result.problems, isEmpty);
      expect(result.intact, isTrue);
      expect(result.digestMatches, isTrue);
      expect(result.signatureValid, isTrue);
      expect(result.coversWholeDocument, isTrue);
      expect(result.signedAt, signedAt);
      expect(result.signerCertificate?.subjectCommonName,
          'Dart PDF Test Signer');
    });

    test('the signature field lands in the AcroForm and on the page', () {
      final doc = PdfDocument.open(signedFixture());
      final form = PdfAcroForm.of(doc)!;
      final field = form.fieldNamed('Signature1')!;
      expect(field.type, PdfFieldType.signature);
      final annots = doc.cos.resolve(doc.page(0).dict['Annots']) as CosArray;
      expect(annots.length, 1);
      final acroForm =
          doc.cos.resolve(doc.catalog['AcroForm']) as CosDictionary;
      expect((doc.cos.resolve(acroForm['SigFlags']) as CosInteger).value, 3);
    });

    test('signing keeps the original bytes (incremental update)', () {
      final original = buildMultiPagePdf(2);
      final editor = PdfEditor(PdfDocument.open(original));
      final signed = editor.saveSigned(
          privateKey: key, certificates: [cert], signingTime: signedAt);
      expect(signed.sublist(0, original.length), original);
    });

    test('an existing empty signature field is reused', () {
      final editor = PdfEditor(PdfDocument.open(buildEmptySigFieldPdf()));
      final signed = editor.saveSigned(
        privateKey: key,
        certificates: [cert],
        fieldName: 'ApproverSig',
        signingTime: signedAt,
      );
      final doc = PdfDocument.open(signed);
      final signature = PdfSignature.of(doc).single;
      expect(signature.field.name, 'ApproverSig');
      expect(signature.validate().intact, isTrue);
      // no second field materialized
      expect(PdfAcroForm.of(doc)!.fields, hasLength(1));
    });

    test('queued edits become part of the signed revision', () {
      final editor = PdfEditor(PdfDocument.open(buildMultiPagePdf(3)))
        ..removePage(2);
      final doc = PdfDocument.open(editor.saveSigned(
          privateKey: key, certificates: [cert], signingTime: signedAt));
      expect(doc.pageCount, 2);
      expect(PdfSignature.of(doc).single.validate().intact, isTrue);
    });
  });

  group('validation', () {
    test('a flipped byte in the signed range breaks the digest', () {
      final signed = signedFixture();
      signed[40] ^= 0x01; // inside page 1's content
      final doc = PdfDocument.open(signed);
      final result = PdfSignature.of(doc).single.validate();
      expect(result.digestMatches, isFalse);
      expect(result.intact, isFalse);
    });

    test('editing after signing demotes coverage but not integrity', () {
      final signedDoc = PdfDocument.open(signedFixture());
      final editor = PdfEditor(signedDoc)..rotatePage(0, 90);
      final doc = PdfDocument.open(editor.save());
      final result = PdfSignature.of(doc).single.validate();
      expect(result.intact, isTrue);
      expect(result.coversWholeDocument, isFalse);
      expect(result.problems.single, contains('updated after'));
    });

    test('a second signature signs the updated whole', () {
      final once = PdfDocument.open(signedFixture());
      final twice = PdfDocument.open(PdfEditor(once).saveSigned(
          privateKey: key,
          certificates: [cert],
          reason: 'Countersign',
          signingTime: signedAt.add(const Duration(days: 1))));
      final signatures = PdfSignature.of(twice);
      expect(signatures, hasLength(2));
      expect(signatures[0].field.name, 'Signature1');
      expect(signatures[1].field.name, 'Signature2');

      final first = signatures[0].validate();
      expect(first.intact, isTrue);
      expect(first.coversWholeDocument, isFalse);

      final second = signatures[1].validate();
      expect(second.intact, isTrue);
      expect(second.coversWholeDocument, isTrue);
    });

    test('a tampered CMS blob fails signature verification', () {
      final signed = signedFixture();
      final doc = PdfDocument.open(signed);
      final signature = PdfSignature.of(doc).single;
      // flip a bit inside the stored signature container itself: find the
      // hex contents and corrupt one digit of the embedded RSA signature
      final contents = signature.contents;
      expect(contents, isNot(everyElement(0)));
      // corrupt the last DER byte (inside the RSA signature octets)
      var end = contents.length - 1;
      while (end > 0 && contents[end] == 0) {
        end--;
      }
      contents[end] ^= 0xFF;
      final result = signature.validate();
      expect(result.signatureValid, isFalse);
      expect(result.digestMatches, isTrue);
    });
  });
}
