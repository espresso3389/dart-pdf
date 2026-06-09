# dart-pdf

A PDF renderer and editor written entirely in Dart, for use in Flutter apps —
no PDFium, no platform channels.

> Status: early development. The COS object layer works (parse real PDF files,
> including cross-reference streams and object streams); rendering and editing
> are in progress.

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
2. Incremental-update writer; document-level editing (merge, split, rotate,
   metadata, form filling)
3. Content-stream interpreter with an abstract device interface
4. Font engine: TrueType/CFF glyph outlines, CID fonts, CMaps, ToUnicode
5. Flutter rendering device + viewer widget (tiling, zoom, selection, search)
6. Content editing tiers: stamping → element deletion → text editing

## Development

This repo uses [fvm](https://fvm.app) (Flutter 3.44.0) and pub workspaces.

```sh
fvm flutter pub get          # resolve the whole workspace
fvm dart analyze
cd packages/pdf_cos && fvm dart test
```
