# Changelog

## 0.1.0

Initial release.

- COS object model: dictionaries, arrays, names, strings, streams, references.
- Lenient tokenizer/parser for real-world PDFs (broken /Length, missing
  `endobj`, junk before the header, broken xref chains with object-scan
  recovery).
- Cross-reference tables and streams; lazy object loading; incremental
  updates.
- Filters: Flate, LZW, RunLength, ASCIIHex, ASCII85, DCT passthrough,
  CCITT G3/G4, JBIG2 (embedded profile), JPEG 2000.
- Encryption: RC4, AES-128, AES-256 decryption and encrypt-on-write.
- Crypto primitives for signing/validation: ASN.1, RSA, ECDSA, CMS,
  X.509 chain verification.
- Content-stream tokenizer and a from-scratch document builder.
