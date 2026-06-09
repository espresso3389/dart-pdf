# dart-pdf

A PDF renderer and editor written entirely in Dart, for use in Flutter apps —
no PDFium, no platform channels.

**End goal:** a PSPDFKit/Nutrient-class SDK — fast viewer, full annotation
suite with appearance-stream generation, AcroForm filling, page manipulation,
and digital-signature-safe editing — built natively for Flutter.

> Status: early development. The COS object layer works (parses real PDF
> files, including cross-reference streams and object streams), and the
> incremental-update writer supports metadata and page-level edits that
> preserve digital signatures. Rendering is the current frontier.

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
3. Encryption (RC4/AES-128/AES-256) — required for business documents
4. Content-stream interpreter with an abstract device interface
5. Font engine: TrueType/CFF glyph outlines, CID fonts, CMaps, ToUnicode
6. Flutter rendering device + viewer widget (tiling, zoom, page cache)
7. Text extraction with positions → selection and search
8. Annotations: model, rendering, **appearance-stream generation**
   (ink, highlight, shapes, free text, notes, stamps), flattening
9. AcroForm: field model, filling, appearance regeneration
10. Page manipulation: reorder, merge, split (cross-document object copying)
11. Digital signatures: signing and validation
12. Content editing tiers: stamping → element deletion → text editing

## Development

This repo uses [fvm](https://fvm.app) (Flutter 3.44.0) and pub workspaces.

```sh
fvm flutter pub get          # resolve the whole workspace
fvm dart analyze
cd packages/pdf_cos && fvm dart test
```
