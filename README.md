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
10. **Page manipulation: reorder, merge, split (cross-document object
    copying)** — next
11. Digital signatures: signing and validation
12. Content editing tiers: stamping → element deletion → text editing

## Development

This repo uses [fvm](https://fvm.app) (Flutter 3.44.0) and pub workspaces.

```sh
fvm flutter pub get          # resolve the whole workspace
fvm dart analyze
cd packages/pdf_cos && fvm dart test
```
