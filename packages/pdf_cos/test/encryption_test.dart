import 'dart:convert';

import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

void main() {
  const expectedContent = 'BT /F1 24 Tf 72 720 Td (Hello, world!) Tj ET';

  void expectDecrypted(CosDocument doc) {
    expect(doc.isEncrypted, isTrue);
    final page = doc.resolve(
        (doc.resolve(doc.catalog['Pages']) as CosDictionary)['Kids']);
    final pageDict =
        doc.resolve((page as CosArray)[0]) as CosDictionary;
    final contents = doc.resolve(pageDict['Contents']) as CosStream;
    expect(latin1.decode(doc.decodeStreamData(contents)), expectedContent);
    final info = doc.resolve(doc.trailer['Info']) as CosDictionary;
    expect((doc.resolve(info['Title']) as CosString).text, 'Secret Title');
  }

  group('decrypts with the empty user password', () {
    for (final (revision, name) in [
      (2, 'R2 RC4 40-bit'),
      (3, 'R3 RC4 128-bit'),
      (4, 'R4 AES-128 (AESV2)'),
      (6, 'R6 AES-256 (AESV3)'),
    ]) {
      test(name, () {
        expectDecrypted(
            CosDocument.open(buildEncryptedPdf(revision: revision)));
      });
    }
  });

  group('decrypts with a non-empty user password', () {
    for (final revision in [2, 3, 4, 6]) {
      test('R$revision', () {
        final bytes =
            buildEncryptedPdf(revision: revision, userPassword: 'hunter2');
        expectDecrypted(CosDocument.open(bytes, password: 'hunter2'));
      });
    }
  });

  group('the owner password opens the document too', () {
    for (final revision in [2, 3, 4, 6]) {
      test('R$revision', () {
        final bytes = buildEncryptedPdf(
            revision: revision,
            userPassword: 'hunter2',
            ownerPassword: 'admin');
        expectDecrypted(CosDocument.open(bytes, password: 'admin'));
      });
    }
  });

  group('a wrong password throws CosPasswordException', () {
    for (final revision in [2, 3, 4, 6]) {
      test('R$revision', () {
        final bytes =
            buildEncryptedPdf(revision: revision, userPassword: 'hunter2');
        expect(() => CosDocument.open(bytes, password: 'wrong'),
            throwsA(isA<CosPasswordException>()));
        // and the empty default is wrong here too
        expect(() => CosDocument.open(bytes),
            throwsA(isA<CosPasswordException>()));
      });
    }
  });

  test('the updater refuses encrypted documents (no re-encryption yet)', () {
    final doc = CosDocument.open(buildEncryptedPdf(revision: 3));
    expect(() => CosIncrementalUpdater(doc),
        throwsA(isA<UnsupportedEncryptionException>()));
  });

  test('unencrypted documents are unaffected', () {
    final doc = CosDocument.open(buildClassicPdf());
    expect(doc.isEncrypted, isFalse);
    expect(doc.encryption, isNull);
  });

  test('the /Encrypt dictionary strings stay raw', () {
    final doc = CosDocument.open(buildEncryptedPdf(revision: 3));
    final encrypt = doc.resolve(doc.trailer['Encrypt']) as CosDictionary;
    final o = doc.resolve(encrypt['O']) as CosString;
    expect(o.bytes, hasLength(32)); // untouched Algorithm 3 output
    expect(doc.encryption!.stringCipher, PdfCipher.rc4);
  });

  test('V4 crypt filters map to the right ciphers', () {
    final doc = CosDocument.open(buildEncryptedPdf(revision: 4));
    expect(doc.encryption!.stringCipher, PdfCipher.aes128);
    expect(doc.encryption!.streamCipher, PdfCipher.aes128);
  });

  test('R6 uses the file key for all content', () {
    final doc = CosDocument.open(buildEncryptedPdf(revision: 6));
    expect(doc.encryption!.revision, 6);
    expect(doc.encryption!.streamCipher, PdfCipher.aes256);
  });
}
