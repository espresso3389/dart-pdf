/// RSA PKCS#1 v1.5 signatures over Dart's native [BigInt.modPow] — used
/// to verify and produce CMS signatures. No padding oracle concerns
/// apply: signing pads deterministically and verification rebuilds the
/// expected encoding and compares.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'asn1.dart';

/// Digest algorithm OIDs paired with their DigestInfo prefixes.
abstract final class DigestOid {
  static const sha1 = '1.3.14.3.2.26';
  static const sha256 = '2.16.840.1.101.3.4.2.1';
  static const sha384 = '2.16.840.1.101.3.4.2.2';
  static const sha512 = '2.16.840.1.101.3.4.2.3';
}

class RsaPublicKey {
  RsaPublicKey(this.modulus, this.exponent);

  /// Parses a PKCS#1 RSAPublicKey: SEQUENCE { n, e }.
  factory RsaPublicKey.fromPkcs1(Uint8List der) {
    final seq = DerObject.parse(der).children;
    return RsaPublicKey(seq[0].asInteger, seq[1].asInteger);
  }

  final BigInt modulus;
  final BigInt exponent;

  int get byteLength => (modulus.bitLength + 7) >> 3;
}

class RsaPrivateKey {
  RsaPrivateKey({
    required this.modulus,
    required this.publicExponent,
    required this.privateExponent,
  });

  /// Parses PKCS#8 PrivateKeyInfo or bare PKCS#1 RSAPrivateKey DER.
  factory RsaPrivateKey.fromDer(Uint8List der) {
    var seq = DerObject.parse(der).children;
    // PKCS#8: SEQUENCE { version, AlgorithmIdentifier, OCTET STRING key }
    if (seq.length == 3 && seq[1].tag == DerTag.sequence) {
      seq = DerObject.parse(seq[2].content).children;
    }
    // PKCS#1: SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }
    return RsaPrivateKey(
      modulus: seq[1].asInteger,
      publicExponent: seq[2].asInteger,
      privateExponent: seq[3].asInteger,
    );
  }

  /// Parses a PEM block (`BEGIN PRIVATE KEY` or `BEGIN RSA PRIVATE KEY`).
  factory RsaPrivateKey.fromPem(String pem) =>
      RsaPrivateKey.fromDer(pemBytes(pem));

  final BigInt modulus;
  final BigInt publicExponent;
  final BigInt privateExponent;

  RsaPublicKey get publicKey => RsaPublicKey(modulus, publicExponent);

  int get byteLength => (modulus.bitLength + 7) >> 3;
}

/// Strips a PEM armor and decodes the base64 body.
Uint8List pemBytes(String pem) {
  final body = pem
      .split('\n')
      .where((line) => !line.contains('-----') && line.trim().isNotEmpty)
      .join();
  return Uint8List.fromList(base64.decode(body));
}

/// DigestInfo ::= SEQUENCE { AlgorithmIdentifier, OCTET STRING digest }
Uint8List _digestInfo(String digestOid, List<int> digest) => derSequence([
      derSequence([derOid(digestOid), derNull()]),
      derOctetString(digest),
    ]);

Uint8List _emsaPkcs1v15(String digestOid, List<int> digest, int length) {
  final info = _digestInfo(digestOid, digest);
  if (length < info.length + 11) {
    throw ArgumentError('RSA key too small for digest');
  }
  return Uint8List.fromList([
    0x00, 0x01,
    ...List.filled(length - info.length - 3, 0xFF),
    0x00,
    ...info,
  ]);
}

BigInt _toBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _toBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var rest = value;
  for (var i = length - 1; i >= 0 && rest > BigInt.zero; i--) {
    out[i] = (rest & BigInt.from(0xFF)).toInt();
    rest >>= 8;
  }
  return out;
}

/// Verifies a PKCS#1 v1.5 signature over a precomputed [digest].
bool rsaVerify(
    RsaPublicKey key, String digestOid, List<int> digest, List<int> signature) {
  final s = _toBigInt(signature);
  if (s >= key.modulus) return false;
  final em = _toBytes(s.modPow(key.exponent, key.modulus), key.byteLength);
  final expected = _emsaPkcs1v15(digestOid, digest, key.byteLength);
  if (em.length != expected.length) return false;
  var diff = 0;
  for (var i = 0; i < em.length; i++) {
    diff |= em[i] ^ expected[i];
  }
  if (diff == 0) return true;
  // some encoders omit the NULL AlgorithmIdentifier parameters
  final altInfo = derSequence([
    derSequence([derOid(digestOid)]),
    derOctetString(digest),
  ]);
  final alt = Uint8List.fromList([
    0x00, 0x01,
    ...List.filled(key.byteLength - altInfo.length - 3, 0xFF),
    0x00,
    ...altInfo,
  ]);
  if (em.length != alt.length) return false;
  diff = 0;
  for (var i = 0; i < em.length; i++) {
    diff |= em[i] ^ alt[i];
  }
  return diff == 0;
}

/// Produces a PKCS#1 v1.5 signature over a precomputed [digest].
Uint8List rsaSign(RsaPrivateKey key, String digestOid, List<int> digest) {
  final em = _emsaPkcs1v15(digestOid, digest, key.byteLength);
  return _toBytes(
      _toBigInt(em).modPow(key.privateExponent, key.modulus), key.byteLength);
}
