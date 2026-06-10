part of 'editor.dart';

/// Signing: writes the pending edits plus a new signature as one
/// incremental update, then fills in the byte range and CMS container.
extension PdfSigning on PdfEditor {
  /// Signs the document and returns the complete signed file. Any edits
  /// queued on this editor are included in the signed revision.
  ///
  /// The signature is `adbe.pkcs7.detached` (CMS, RSA PKCS#1 v1.5 with
  /// SHA-256). [certificates] is the signer's DER chain, leaf first; its
  /// subject becomes the visible signer unless [signerName] overrides it.
  /// An existing empty signature field called [fieldName] is used when
  /// present, otherwise an invisible signature field is created on the
  /// first page. After this call the editor is spent — saving again
  /// would invalidate the signature it just produced.
  Uint8List saveSigned({
    required RsaPrivateKey privateKey,
    required List<Uint8List> certificates,
    String? fieldName,
    String? signerName,
    String? reason,
    String? location,
    String? contactInfo,
    DateTime? signingTime,
  }) {
    if (certificates.isEmpty) {
      throw ArgumentError('the signer certificate is required');
    }
    if (document.cos.isEncrypted) {
      // the signature /Contents and /ByteRange must stay unencrypted and
      // byte-patchable in the written file; encrypt-on-write would
      // scramble the placeholders this method patches
      throw UnsupportedEncryptionException(
          'signing encrypted documents is not supported yet');
    }
    final cos = document.cos;
    final time = (signingTime ?? DateTime.now()).toUtc();

    // generous space for the CMS: certificates, attributes, signature
    var capacity = 2048;
    for (final cert in certificates) {
      capacity += cert.length;
    }
    final placeholder = Uint8List(capacity);

    final sigDict = CosDictionary({
      'Type': const CosName('Sig'),
      'Filter': const CosName('Adobe.PPKLite'),
      'SubFilter': const CosName('adbe.pkcs7.detached'),
      'ByteRange': CosArray([
        const CosInteger(0),
        CosInteger(_rangePlaceholder),
        CosInteger(_rangePlaceholder),
        CosInteger(_rangePlaceholder),
      ]),
      'Contents': CosString(placeholder, isHex: true),
      'M': CosString.fromText(_pdfDate(time)),
      if (signerName != null || _subjectCn(certificates.first) != null)
        'Name': CosString.fromText(
            signerName ?? _subjectCn(certificates.first)!),
      if (reason != null) 'Reason': CosString.fromText(reason),
      if (location != null) 'Location': CosString.fromText(location),
      if (contactInfo != null)
        'ContactInfo': CosString.fromText(contactInfo),
    });
    final sigRef = _updater.addObject(sigDict);
    _attachSignatureField(sigRef, fieldName);

    final saved = _updater.save();

    // locate the placeholders in the appended update
    final tailStart = cos.bytes.length;
    final hexLength = placeholder.length * 2;
    final contentsStart = _find(
        saved, tailStart, '<${'0' * hexLength}>'.codeUnits);
    if (contentsStart < 0) {
      throw StateError('signature placeholder not found in output');
    }
    final contentsEnd = contentsStart + hexLength + 2;
    final rangeToken = '[0 $_rangePlaceholder $_rangePlaceholder '
        '$_rangePlaceholder]';
    final rangeStart = _find(saved, tailStart, rangeToken.codeUnits);
    if (rangeStart < 0) {
      throw StateError('byte-range placeholder not found in output');
    }

    final byteRange =
        '[0 $contentsStart $contentsEnd ${saved.length - contentsEnd}]'
            .padRight(rangeToken.length)
            .codeUnits;
    saved.setRange(rangeStart, rangeStart + byteRange.length, byteRange);

    final signedBytes = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(saved, 0, contentsStart))
      ..add(Uint8List.sublistView(saved, contentsEnd));
    final digest = crypto.sha256.convert(signedBytes.takeBytes()).bytes;
    final cms = cmsSignDetached(
      contentDigest: digest,
      privateKey: privateKey,
      certificates: certificates,
      signingTime: time,
    );
    if (cms.length > placeholder.length) {
      throw StateError('CMS signature exceeded its reserved space');
    }
    const hexDigits = '0123456789ABCDEF';
    for (var i = 0; i < cms.length; i++) {
      saved[contentsStart + 1 + i * 2] =
          hexDigits.codeUnitAt(cms[i] >> 4);
      saved[contentsStart + 2 + i * 2] =
          hexDigits.codeUnitAt(cms[i] & 0xF);
    }
    return saved;
  }

  /// Ten digits so the patched real values always fit.
  static const _rangePlaceholder = 9999999999;

  static String _pdfDate(DateTime utc) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'D:${utc.year}${two(utc.month)}${two(utc.day)}'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  static String? _subjectCn(Uint8List certDer) {
    try {
      return X509Certificate.parse(certDer).subjectCommonName;
    } on Object {
      return null;
    }
  }

  static int _find(Uint8List haystack, int from, List<int> needle) {
    outer:
    for (var i = from; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// Points an existing empty signature field at [sigRef], or creates an
  /// invisible one on the first page.
  void _attachSignatureField(CosReference sigRef, String? fieldName) {
    final cos = document.cos;
    final form = PdfAcroForm.of(document);

    if (fieldName != null && form != null) {
      final existing = form.fieldNamed(fieldName);
      if (existing != null) {
        if (existing.type != PdfFieldType.signature) {
          throw ArgumentError('field "$fieldName" is not a signature field');
        }
        if (cos.resolve(existing.dict['V']) is CosDictionary) {
          throw StateError('field "$fieldName" is already signed');
        }
        existing.dict['V'] = sigRef;
        _updater.markChanged(existing.dict);
        _ensureSigFlags();
        return;
      }
    }

    final page = document.page(0);
    final pageRef = cos.referenceTo(page.dict);
    final name = fieldName ?? _freshFieldName(form);
    final fieldDict = CosDictionary({
      'FT': const CosName('Sig'),
      'T': CosString.fromText(name),
      'V': sigRef,
      'Type': const CosName('Annot'),
      'Subtype': const CosName('Widget'),
      'Rect': CosArray([
        const CosInteger(0), const CosInteger(0), //
        const CosInteger(0), const CosInteger(0),
      ]),
      'F': const CosInteger(132), // print + locked
      if (pageRef != null) 'P': pageRef,
    });
    final fieldRef = _updater.addObject(fieldDict);

    // page /Annots
    final annots = cos.resolve(page.dict['Annots']);
    if (annots is CosArray) {
      annots.items.add(fieldRef);
      final annotsRef = page.dict['Annots'];
      if (annotsRef is CosReference) {
        _updater.replaceObject(annotsRef.objectNumber, annots);
      } else {
        _updater.markChanged(page.dict);
      }
    } else {
      page.dict['Annots'] = CosArray([fieldRef]);
      _updater.markChanged(page.dict);
    }

    // AcroForm /Fields
    final acroForm = cos.resolve(document.catalog['AcroForm']);
    if (acroForm is CosDictionary) {
      final fields = cos.resolve(acroForm['Fields']);
      if (fields is CosArray) {
        fields.items.add(fieldRef);
      } else {
        acroForm['Fields'] = CosArray([fieldRef]);
      }
      acroForm['SigFlags'] = const CosInteger(3);
      final acroRef = document.catalog['AcroForm'];
      if (acroRef is CosReference) {
        _updater.replaceObject(acroRef.objectNumber, acroForm);
      } else {
        _updater.markChanged(document.catalog);
      }
    } else {
      document.catalog['AcroForm'] = _updater.addObject(CosDictionary({
        'Fields': CosArray([fieldRef]),
        'SigFlags': const CosInteger(3),
      }));
      _updater.markChanged(document.catalog);
    }
  }

  void _ensureSigFlags() {
    final cos = document.cos;
    final acroForm = cos.resolve(document.catalog['AcroForm']);
    if (acroForm is! CosDictionary) return;
    final flags = cos.resolve(acroForm['SigFlags']);
    final current = flags is CosInteger ? flags.value : 0;
    if (current & 3 != 3) {
      acroForm['SigFlags'] = CosInteger(current | 3);
      final acroRef = document.catalog['AcroForm'];
      if (acroRef is CosReference) {
        _updater.replaceObject(acroRef.objectNumber, acroForm);
      } else {
        _updater.markChanged(document.catalog);
      }
    }
  }

  String _freshFieldName(PdfAcroForm? form) {
    final taken = {
      if (form != null)
        for (final field in form.fields) field.name,
    };
    var i = 1;
    while (taken.contains('Signature$i')) {
      i++;
    }
    return 'Signature$i';
  }
}
