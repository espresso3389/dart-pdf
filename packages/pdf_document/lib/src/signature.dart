import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pdf_cos/pdf_cos.dart';

import 'document.dart';
import 'form.dart';

/// A signed signature field: the /V signature dictionary of an AcroForm
/// field with /FT /Sig (§12.8).
class PdfSignature {
  PdfSignature._(this.document, this.field, this.dict);

  final PdfDocument document;
  final PdfFormField field;

  /// The signature dictionary (/Type /Sig).
  final CosDictionary dict;

  /// All signed signature fields, in field order.
  static List<PdfSignature> of(PdfDocument document) {
    final form = PdfAcroForm.of(document);
    if (form == null) return const [];
    return [
      for (final field in form.fields)
        if (field.type == PdfFieldType.signature)
          if (document.cos.resolve(field.dict['V'])
              case final CosDictionary v)
            PdfSignature._(document, field, v),
    ];
  }

  String? _text(String key) {
    final value = document.cos.resolve(dict[key]);
    return value is CosString ? value.text : null;
  }

  /// Signer name as recorded by the signing software (/Name).
  String? get signerName => _text('Name');

  String? get reason => _text('Reason');
  String? get location => _text('Location');
  String? get contactInfo => _text('ContactInfo');

  /// /SubFilter, e.g. `adbe.pkcs7.detached` or `ETSI.CAdES.detached`.
  String? get subFilter {
    final value = document.cos.resolve(dict['SubFilter']);
    return value is CosName ? value.value : null;
  }

  /// Claimed signing time from /M (the cryptographic signingTime
  /// attribute, when present, is reported by [validate]).
  DateTime? get signingTime {
    final m = _text('M');
    if (m == null) return null;
    final match = RegExp(
            r"D:(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?(?:([+\-Z])(\d{2})?'?(\d{2})?)?")
        .firstMatch(m);
    if (match == null) return null;
    int part(int i, [int fallback = 0]) =>
        match.group(i) == null ? fallback : int.parse(match.group(i)!);
    var time = DateTime.utc(part(1), part(2, 1), part(3, 1), part(4),
        part(5), part(6));
    if (match.group(7) == '+' || match.group(7) == '-') {
      final offset = Duration(hours: part(8), minutes: part(9));
      time = match.group(7) == '+' ? time.subtract(offset) : time.add(offset);
    }
    return time;
  }

  /// The [start, length, start, length] pairs of signed bytes.
  List<int> get byteRange {
    final array = document.cos.resolve(dict['ByteRange']);
    if (array is! CosArray) return const [];
    return [
      for (final item in array.items)
        if (document.cos.resolve(item) case final CosInteger n) n.value,
    ];
  }

  /// The raw CMS (or PKCS#1) signature blob.
  Uint8List get contents {
    final value = document.cos.resolve(dict['Contents']);
    return value is CosString ? value.bytes : Uint8List(0);
  }

  /// Checks the signature against the document bytes: range coverage,
  /// digest, and the cryptographic signature against the embedded
  /// certificate. Chain-of-trust against a root store is not evaluated.
  PdfSignatureValidation validate() {
    final bytes = document.cos.bytes;
    final problems = <String>[];
    final ranges = byteRange;

    var rangesSane = ranges.length == 4 &&
        ranges[0] == 0 &&
        ranges[1] >= 0 &&
        ranges[2] >= ranges[1] &&
        ranges[3] >= 0 &&
        ranges[2] + ranges[3] <= bytes.length;
    if (!rangesSane) {
      problems.add('malformed /ByteRange');
    } else {
      // the gap must hold exactly the /Contents hex string
      final gapStart = ranges[0] + ranges[1];
      final gapEnd = ranges[2];
      if (gapStart >= gapEnd ||
          bytes[gapStart] != 0x3C /* < */ ||
          bytes[gapEnd - 1] != 0x3E /* > */) {
        problems.add('/ByteRange gap does not hold the signature');
        rangesSane = false;
      }
    }
    final coversWholeDocument = rangesSane &&
        ranges[2] + ranges[3] == bytes.length;
    if (rangesSane && !coversWholeDocument) {
      problems.add('the document was updated after this signature; only '
          'the signed revision is covered');
    }
    if (!rangesSane) {
      return PdfSignatureValidation._(
          false, false, false, null, const [], const [], problems);
    }

    final data = Uint8List(ranges[1] + ranges[3]);
    data.setRange(0, ranges[1], bytes);
    data.setRange(ranges[1], data.length,
        Uint8List.sublistView(bytes, ranges[2], ranges[2] + ranges[3]));

    switch (subFilter) {
      case 'adbe.x509.rsa_sha1':
        return _validateX509RsaSha1(data, coversWholeDocument, problems);
      case 'adbe.pkcs7.sha1':
        return _validateCms(data, coversWholeDocument, problems,
            digestOfRanges: true);
      default: // adbe.pkcs7.detached, ETSI.CAdES.detached
        return _validateCms(data, coversWholeDocument, problems);
    }
  }

  PdfSignatureValidation _validateCms(
      Uint8List data, bool coversWholeDocument, List<String> problems,
      {bool digestOfRanges = false}) {
    final CmsSignedData cms;
    try {
      cms = CmsSignedData.parse(contents);
    } on Object catch (e) {
      problems.add('cannot parse CMS signature: $e');
      return PdfSignatureValidation._(false, false, coversWholeDocument,
          null, const [], const [], problems);
    }
    if (cms.signerInfos.isEmpty) {
      problems.add('CMS has no signer');
      return PdfSignatureValidation._(false, false, coversWholeDocument,
          null, cms.certificates, const [], problems);
    }
    final signer = cms.signerInfos.first;

    List<int> content = data;
    var sha1Matches = true;
    if (digestOfRanges) {
      // adbe.pkcs7.sha1: the CMS encapsulates SHA-1 of the byte ranges
      final eContent = cms.eContent;
      if (eContent == null) {
        problems.add('adbe.pkcs7.sha1 signature has no encapsulated digest');
        return PdfSignatureValidation._(false, false, coversWholeDocument,
            cms.certificateFor(signer), cms.certificates, const [], problems);
      }
      final rangesDigest = crypto.sha1.convert(data).bytes;
      sha1Matches = _equal(rangesDigest, eContent);
      if (!sha1Matches) problems.add('document digest mismatch');
      content = eContent;
    }

    final verification = cmsVerify(cms, signer, content);
    if (verification.problem != null) problems.add(verification.problem!);
    final digestMatches = verification.digestMatches && sha1Matches;
    if (!verification.digestMatches) problems.add('signed digest mismatch');
    if (!verification.signatureValid && verification.problem == null) {
      problems.add('cryptographic signature is invalid');
    }
    return PdfSignatureValidation._(
      digestMatches,
      verification.signatureValid,
      coversWholeDocument,
      cms.certificateFor(signer),
      cms.certificates,
      signer.signingTime != null ? [signer.signingTime!] : const [],
      problems,
    );
  }

  PdfSignatureValidation _validateX509RsaSha1(
      Uint8List data, bool coversWholeDocument, List<String> problems) {
    final certValue = document.cos.resolve(dict['Cert']);
    final certBytes = switch (certValue) {
      CosString s => s.bytes,
      CosArray a when a.length > 0 =>
        (document.cos.resolve(a[0]) as CosString).bytes,
      _ => null,
    };
    if (certBytes == null) {
      problems.add('adbe.x509.rsa_sha1 signature has no /Cert');
      return PdfSignatureValidation._(false, false, coversWholeDocument,
          null, const [], const [], problems);
    }
    final cert = X509Certificate.parse(certBytes);
    final key = cert.publicKey;
    if (key is! RsaPublicKey) {
      problems.add('unsupported key algorithm ${cert.publicKeyAlgorithmOid}');
      return PdfSignatureValidation._(false, false, coversWholeDocument,
          cert, [cert], const [], problems);
    }
    // /Contents is a DER OCTET STRING wrapping the PKCS#1 signature
    var signature = contents;
    try {
      final wrapped = DerObject.parsePrefix(signature);
      if (wrapped.tag == DerTag.octetString) signature = wrapped.content;
    } on Object {
      // raw signature bytes
    }
    final valid = rsaVerify(
        key, DigestOid.sha1, crypto.sha1.convert(data).bytes, signature);
    if (!valid) problems.add('cryptographic signature is invalid');
    return PdfSignatureValidation._(
        valid, valid, coversWholeDocument, cert, [cert], const [], problems);
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Outcome of validating one signature.
class PdfSignatureValidation {
  PdfSignatureValidation._(
    this.digestMatches,
    this.signatureValid,
    this.coversWholeDocument,
    this.signerCertificate,
    this.certificates,
    List<DateTime> signingTimes,
    this.problems,
  ) : signedAt = signingTimes.isEmpty ? null : signingTimes.first;

  /// The signed bytes still hash to the digest embedded in the signature.
  final bool digestMatches;

  /// The signature verifies against the signer certificate's public key.
  final bool signatureValid;

  /// The byte range spans the entire file. False means the document
  /// received incremental updates after signing — common and legitimate
  /// (later signatures, form fills), but only the signed revision is
  /// attested.
  final bool coversWholeDocument;

  /// The certificate the signature verifies against. Trust in this
  /// certificate is NOT established by [PdfSignature.validate].
  final X509Certificate? signerCertificate;

  /// Every certificate shipped with the signature.
  final List<X509Certificate> certificates;

  /// The cryptographically signed signing time, when present.
  final DateTime? signedAt;

  final List<String> problems;

  /// The document bytes the signature covers are exactly what was signed.
  bool get intact => digestMatches && signatureValid;
}
