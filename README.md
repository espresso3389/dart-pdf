# dart-pdf

A PDF renderer and editor written entirely in Dart, for use in Flutter apps —
no PDFium, no platform channels.

**End goal:** a PSPDFKit/Nutrient-class SDK — fast viewer, full annotation
suite with appearance-stream generation, AcroForm filling, page manipulation,
and digital-signature-safe editing — built natively for Flutter.

> Status: the core pipeline works end to end — COS parsing (including
> cross-reference and object streams), signature-preserving incremental
> updates, a content-stream interpreter with TrueType/CFF font rendering,
> a zoomable Flutter viewer with text selection and search, rendering of
> annotation appearance streams, annotation authoring and flattening,
> AcroForm filling, and decryption of encrypted documents
> (RC4/AES-128/AES-256). Current frontier: page manipulation.

## Architecture

Strictly layered packages; `dart:ui` is only allowed in `pdf_flutter`, so the
core runs on servers and in plain Dart tests.

| Package | Role |
|---|---|
| `packages/pdf_cos` | The PDF file format itself: tokenizer, parser, filters, cross-reference machinery, serializer. |
| `packages/pdf_document` | Document semantics: page tree, inherited attributes, info, (later) annotations and forms. |
| `packages/pdf_graphics` | Content-stream parsing and (later) the interpreter + device interface and font engine. |
| `packages/pdf_flutter` | Canvas-backed rendering device and viewer widgets. |

## Roadmap

1. ✅ COS reader: lexer, parser, FlateDecode + predictors, xref tables,
   xref streams, object streams
2. ✅ Incremental-update writer (signature-preserving); first edits:
   metadata, page rotation
3. ✅ Encryption: opening RC4/AES-128/AES-256 documents (user and owner
   passwords; encrypting on write is still pending, so encrypted files are
   read-only for now)
4. ✅ Content-stream interpreter with an abstract device interface
5. ✅ Font engine: TrueType/CFF glyph outlines, CID fonts, CMaps, ToUnicode
6. ✅ Flutter rendering device + viewer widget (zoom, page cache; deep-zoom
   tiling still pending)
7. ✅ Text extraction with positions → selection and search
8. ✅ Annotations: model, appearance-stream rendering, authoring with
   generated appearances (highlight/underline/strike-out/squiggly, ink,
   shapes, free text, notes, stamps), and flattening
9. ✅ AcroForm: field model (text, check box, radio, choice), filling
   with regenerated appearances (auto-size, multiline wrap, quadding,
   /MK decorations)
10. ✅ Page manipulation: reorder/move, remove, merge with cross-document
    object copying (`appendPagesFrom`), and split (`extractPages` writes a
    standalone file; extracting from an encrypted document decrypts)
11. ✅ Digital signatures: validation (CMS/PKCS#7 with RSA and ECDSA
    P-256/384/521, byte-range and revision-coverage checks; trust-store
    chain evaluation not included) and signing (`saveSigned` —
    adbe.pkcs7.detached, RSA-SHA256, verified interoperable with
    OpenSSL and poppler)
12. ✅ Content editing tiers: stamping (`stampPage` — text, shapes,
    JPEG images over existing content), element deletion
    (`PdfPageElements` enumerates text runs/paths/images with
    approximate bounds; `deleteElements` rewrites the stream), and text
    editing (`replaceText` — single-byte fonts, within one shown string;
    no reflow)

The roadmap is complete. Current work: polish and the editing UI in
`pdf_flutter` (deep-zoom tiling, encrypt-on-write, trust-store chain
validation, and richer text editing remain open).

## Development

This repo uses [fvm](https://fvm.app) (Flutter 3.44.0) and pub workspaces.

```sh
fvm flutter pub get          # resolve the whole workspace
fvm dart analyze
cd packages/pdf_cos && fvm dart test
```
