import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pdf_cos/pdf_cos.dart';
import 'package:test/test.dart';

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

void main() {
  group('DER', () {
    test('integers round-trip including the sign-padding byte', () {
      for (final value in [0, 1, 127, 128, 255, 256, 65537, 1 << 40]) {
        final encoded = derInteger(BigInt.from(value));
        expect(DerObject.parse(encoded).asInteger, BigInt.from(value),
            reason: '$value');
      }
    });

    test('OIDs round-trip through multi-byte arcs', () {
      for (final oid in [
        '1.2.840.113549.1.7.2',
        '2.16.840.1.101.3.4.2.1',
        '1.3.14.3.2.26',
        '2.5.4.3',
      ]) {
        expect(DerObject.parse(derOid(oid)).asOid, oid);
      }
    });

    test('long-form lengths parse', () {
      final blob = derOctetString(List.filled(300, 0xAB));
      final parsed = DerObject.parse(blob);
      expect(parsed.content.length, 300);
      expect(parsed.content.first, 0xAB);
    });

    test('UTCTime applies the RFC 5280 century split and zone offsets', () {
      DerObject time(String text) =>
          DerObject(DerTag.utcTime, Uint8List.fromList(text.codeUnits),
              Uint8List(0));
      expect(time('260610120000Z').asTime, DateTime.utc(2026, 6, 10, 12));
      expect(time('990101000000Z').asTime, DateTime.utc(1999, 1, 1));
      expect(time('260610120000+1000').asTime,
          DateTime.utc(2026, 6, 10, 2));
    });

    test('SET OF sorts element encodings', () {
      final set = derSetOf([
        derOctetString([2, 2]),
        derOctetString([1]),
        derOctetString([2, 1]),
      ]);
      final children = DerObject.parse(set).children;
      expect(children[0].content, [1]);
      expect(children[1].content, [2, 1]);
      expect(children[2].content, [2, 2]);
    });
  });

  group('RSA', () {
    final key = RsaPrivateKey.fromPem(_testKeyPem);

    test('sign/verify round-trip', () {
      final digest = crypto.sha256.convert('payload'.codeUnits).bytes;
      final signature = rsaSign(key, DigestOid.sha256, digest);
      expect(rsaVerify(key.publicKey, DigestOid.sha256, digest, signature),
          isTrue);
    });

    test('a wrong digest fails', () {
      final digest = crypto.sha256.convert('payload'.codeUnits).bytes;
      final other = crypto.sha256.convert('payIoad'.codeUnits).bytes;
      final signature = rsaSign(key, DigestOid.sha256, digest);
      expect(rsaVerify(key.publicKey, DigestOid.sha256, other, signature),
          isFalse);
    });

    test('a corrupted signature fails', () {
      final digest = crypto.sha256.convert('payload'.codeUnits).bytes;
      final signature = rsaSign(key, DigestOid.sha256, digest);
      signature[10] ^= 1;
      expect(rsaVerify(key.publicKey, DigestOid.sha256, digest, signature),
          isFalse);
    });
  });

  group('ECDSA', () {
    // vector produced with openssl: prime256v1 key, SHA-256 over
    // 'dart-pdf ecdsa test message'
    final point = hex(
        '0474b3716c54da98198598597f2277100c820378f9b508258d40c7ef14eeb23a'
        '17ee503509bde66c5197460a1ed5053dbae06cba330a7caf4b6fa2a4a65998be'
        'c1');
    final signature = hex(
        '3046022100b4c0cc2dd62b158db0799c3a45f4ad24e2e2c4ca51fcdf2fc2ccd6'
        '79214782f9022100efb780dff41b1ea52da3abdf33c6055426a10ae3d393e4d1'
        '3e6b69773eab4d3b');

    test('verifies an openssl-produced P-256 signature', () {
      final key = EcPublicKey.fromPoint(EcCurve.p256, point);
      final digest = crypto.sha256
          .convert('dart-pdf ecdsa test message'.codeUnits)
          .bytes;
      expect(ecdsaVerify(key, digest, signature), isTrue);
    });

    test('rejects a corrupted digest', () {
      final key = EcPublicKey.fromPoint(EcCurve.p256, point);
      final digest = crypto.sha256
          .convert('dart-pdf ecdsa test messagE'.codeUnits)
          .bytes;
      expect(ecdsaVerify(key, digest, signature), isFalse);
    });
  });
}

/// A throwaway 1024-bit key for fast unit tests (test-only material).
const _testKeyPem = '''
-----BEGIN RSA PRIVATE KEY-----
MIICXAIBAAKBgQDH8QUQ4tO5Pxwm/aYhem1WLTlPemNnMGCFuSIdtZbXQzCMAR6f
XQzvi5fI3+xcVT/FsfsgJ85PltHrnaygOfbopb0DBJxzipPw7sqi5Aj+fxt86oou
pUWtasX3q0RMIwpW/rg0KVxM9FHWfR7lEwlh5qEuNigJAP6R6+gtTgXPUQIDAQAB
AoGBAKptiKrvHhgecmnN9ik9SSuW2u4jXc3cj7oMp8b5PX15+Uytu6ON1nPt4lDI
hpnh1L04S94J8DMpVQBo43ekURBVtJgU10UyKfMU/68yX++RTIj32cKPYG2ELm8x
VVqhhrG4kX5r3sx4hzXc3SCUE8xGV4s4tR4PE9ycmfa6R4GRAkEA780E0rGF+iyN
+332VOIkKY7MEQK/OeMaqBEjveevN3YvcPRRl5aNpFR2QV2oFmzjmja9WiHs7uNh
or5Urc6fbQJBANVysgU2YYfGKd6INMvUc+NgkWSJFnJn3LU0xNLpsI/daCibZJPG
KH8M4ug0RjJqEtNnIS4R5Ic6y+fQ/xiSrPUCQG4wBMFTtT5pbqxbCu+iIf++j+JZ
IslUo5EKnyPJ6+dONSpv+XXwRhF2hggvIud7DXJ1KLjb0eVLMjf3wS1EPlkCQBt9
AeAZ+MV7h7jY4bO+UI5fyVmhLfrd1VagzRg8cDiW0usn1/QP+PcjubUdxkyHzJTd
GzDLrRqdP9VC3RdVDGECQFUB8LSAUJWdsoBo5eINofTwRAnbUIKp81X5Pwza2USF
+5xq8zloUddInXMCk28Ea5qqKwQ7wyGX2tk+Hy2G9YI=
-----END RSA PRIVATE KEY-----
''';
