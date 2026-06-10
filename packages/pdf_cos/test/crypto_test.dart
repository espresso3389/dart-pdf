import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf_cos/src/crypto/aes.dart';
import 'package:pdf_cos/src/crypto/rc4.dart';
import 'package:test/test.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(' ', '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

void main() {
  group('RC4 (classic published vectors)', () {
    test('"Key" / "Plaintext"', () {
      final out = rc4(ascii.encode('Key'),
          Uint8List.fromList(ascii.encode('Plaintext')));
      expect(out, hex('BBF316E8D940AF0AD3'));
    });

    test('"Secret" / "Attack at dawn"', () {
      final out = rc4(ascii.encode('Secret'),
          Uint8List.fromList(ascii.encode('Attack at dawn')));
      expect(out, hex('45A01F645FC35B383552544B9BF5'));
    });

    test('round-trips', () {
      final key = ascii.encode('any key');
      final data = Uint8List.fromList(List.generate(100, (i) => i * 7 & 0xFF));
      expect(rc4(key, rc4(key, data)), data);
    });
  });

  group('AES (FIPS 197 + NIST SP 800-38A vectors)', () {
    test('AES-128 single block (FIPS 197 C.1, zero-IV CBC = ECB)', () {
      final aes = Aes(hex('000102030405060708090a0b0c0d0e0f'));
      final out = aes.cbcEncrypt(
          Uint8List(16), hex('00112233445566778899aabbccddeeff'));
      expect(out, hex('69c4e0d86a7b0430d8cdb78070b4c55a'));
    });

    test('AES-256 single block (FIPS 197 C.3)', () {
      final aes = Aes(
          hex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'));
      final out = aes.cbcEncrypt(
          Uint8List(16), hex('00112233445566778899aabbccddeeff'));
      expect(out, hex('8ea2b7ca516745bfeafc49904b496089'));
    });

    test('AES-128-CBC encrypt (SP 800-38A F.2.1)', () {
      final aes = Aes(hex('2b7e151628aed2a6abf7158809cf4f3c'));
      final out = aes.cbcEncrypt(
        hex('000102030405060708090a0b0c0d0e0f'),
        hex('6bc1bee22e409f96e93d7e117393172a'
            'ae2d8a571e03ac9c9eb76fac45af8e51'),
      );
      expect(
          out,
          hex('7649abac8119b246cee98e9b12e9197d'
              '5086cb9b507219ee95db113a917678b2'));
    });

    test('AES-128-CBC decrypt (SP 800-38A F.2.2)', () {
      final aes = Aes(hex('2b7e151628aed2a6abf7158809cf4f3c'));
      final out = aes.cbcDecrypt(
        hex('000102030405060708090a0b0c0d0e0f'),
        hex('7649abac8119b246cee98e9b12e9197d'
            '5086cb9b507219ee95db113a917678b2'),
      );
      expect(
          out,
          hex('6bc1bee22e409f96e93d7e117393172a'
              'ae2d8a571e03ac9c9eb76fac45af8e51'));
    });

    test('AES-256-CBC encrypt (SP 800-38A F.2.5)', () {
      final aes = Aes(
          hex('603deb1015ca71be2b73aef0857d7781'
              '1f352c073b6108d72d9810a30914dff4'));
      final out = aes.cbcEncrypt(
        hex('000102030405060708090a0b0c0d0e0f'),
        hex('6bc1bee22e409f96e93d7e117393172a'),
      );
      expect(out, hex('f58c4c04d6e5f1ba779eabfb5f7bfbd6'));
    });

    test('content decryption strips the IV prefix and PKCS#7 padding', () {
      final key = hex('2b7e151628aed2a6abf7158809cf4f3c');
      final plain = Uint8List.fromList(ascii.encode('BT /F1 12 Tf ET'));
      // pad to a block boundary the PKCS#7 way
      final pad = 16 - plain.length % 16;
      final padded = Uint8List.fromList(
          [...plain, for (var i = 0; i < pad; i++) pad]);
      final iv = hex('101112131415161718191a1b1c1d1e1f');
      final cipher = Aes(key).cbcEncrypt(iv, padded);
      final payload = Uint8List.fromList([...iv, ...cipher]);
      expect(Aes.decryptContent(key, payload), plain);
    });

    test('content decryption tolerates short or garbage payloads', () {
      final key = hex('2b7e151628aed2a6abf7158809cf4f3c');
      expect(Aes.decryptContent(key, Uint8List(0)), isEmpty);
      expect(Aes.decryptContent(key, Uint8List(16)), isEmpty);
      // not block-aligned: trailing partial block ignored, no throw
      expect(() => Aes.decryptContent(key, Uint8List(45)), returnsNormally);
    });
  });
}
