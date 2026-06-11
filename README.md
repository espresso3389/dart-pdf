# dart-pdf

A PDF renderer and editor written entirely in Dart, for use in Flutter apps —
no PDFium, no platform channels.

**End goal:** a PSPDFKit/Nutrient-class SDK — fast viewer, full annotation
suite with appearance-stream generation, AcroForm filling, page manipulation,
and digital-signature-safe editing — built natively for Flutter.

> Status: the full roadmap below is complete — COS parsing (with xref
> recovery for broken files), signature-preserving incremental updates
> with encrypt-on-write, a content-stream interpreter with
> TrueType/CFF/Type3 font rendering, mesh shadings, and real ICC color,
> pure-Dart CCITT/JBIG2/JPEG 2000 image decoders, a zoomable Flutter
> viewer with deep-zoom detail rendering, text selection, search, and
> rotated-page support, annotation authoring and flattening, AcroForm
> filling, page manipulation, digital signatures with trust-store chain
> validation, and content editing. Current frontier: the editing UI.

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
   passwords) and encrypt-on-write, so encrypted documents are editable
   (signing them is still refused — the signature byte ranges must stay
   plaintext-patchable)
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

The roadmap is complete, and the former gap list has been closed too:
encrypt-on-write, certificate chain validation against a trust store,
mesh shadings (types 4–7), pure-Dart CCITT/JBIG2/JPEG 2000 decoders,
deep-zoom detail rendering, and real ICC color management all landed.

The editing UI shipped with `pdf_flutter`: a `PdfEditingController`
(edit session with zero-cost undo/redo — incremental updates make every
revision a byte prefix of the next, so undo is just a shorter view of
the same buffer), tool overlays on every page (text markup from the
selection, ink, shapes, free text, notes, stamps; select/move/resize
with handles; a content tool that selects page elements for deletion or
in-place text replacement), keyboard shortcuts, style controls (stroke
width, opacity, font size), an annotation list sidebar
(`PdfAnnotationSidebar`), a page thumbnail sidebar
(`PdfThumbnailSidebar` — tap to jump, drag to reorder pages, delete,
with a live viewport indicator), a full-spectrum color picker with an
eyedropper that samples colors from the rendered page — with a live
swatch-and-hex preview riding beside the pointer
(`PdfColorPicker`), and a ready-made `PdfEditingToolbar`.
A signature tool rounds out the annotation suite: draw a signature
once in a pad dialog (`showPdfSignatureDialog` — pressure-sensitive,
like the ink tool), and tap pages to stamp it as an Ink annotation;
the signature is saved on the device and reused across documents and
sessions. UI preferences persist on the device by default
(`PdfEditingPreferences`, backed by `shared_preferences`): color,
stroke width, opacity, font size, the stylus/finger mode, and panel
visibility all come back the way the user left them.
Apple Pencil (and any stylus) is first-class for ink: strokes record
pressure and render with variable width, and the first pen contact
turns on palm rejection — fingers scroll while the pen draws.
The viewer opens fitted to the whole page like desktop browser viewers
(`PdfViewer.initialFit`). Still
open: richer text editing (reflow),
RSASSA-PSS signatures, JBIG2 Huffman/refinement variants, and JPX
subsampling/PCRL-CPRL progressions.

## Development

This repo uses [fvm](https://fvm.app) (Flutter 3.44.0) and pub workspaces.

```sh
fvm flutter pub get          # resolve the whole workspace
fvm dart analyze
cd packages/pdf_cos && fvm dart test
```
