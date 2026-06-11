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
with handles, with a live translucent preview of the annotation's
artwork riding along while it moves or stretches; a rotate handle
above the selection spins the annotation freely (snapping near 45°
steps), folding the rotation into the appearance stream's matrix so
any conforming viewer renders it rotated; a content tool that
selects page elements for deletion or
in-place text replacement), keyboard shortcuts, style controls (stroke
width, opacity, font size), an annotation list sidebar
(`PdfAnnotationSidebar` — grouped by page with each annotation's
author shown; tapping a tile zooms the viewer to the annotation, and
a long press starts multi-select for deleting a whole set as one
undo step), a page thumbnail sidebar
(`PdfThumbnailSidebar` — tap to jump, drag to reorder pages, delete,
with a live viewport indicator), a full-spectrum color picker with an
eyedropper that samples colors from the rendered page — with a live
swatch-and-hex preview riding beside the pointer
(`PdfColorPicker`), and a ready-made `PdfEditingToolbar`.
A signature tool rounds out the annotation suite: draw a signature
once in a pad dialog (`showPdfSignatureDialog` — pressure-sensitive,
like the ink tool), and tap pages to stamp it as an Ink annotation;
the signature is saved on the device and reused across documents and
sessions. Custom rubber stamps work the same way: author a
caption-and-color stamp once in the stamp picker, and from then on a
tap places it — the collection is saved on the device. UI preferences persist on the device by default
(`PdfEditingPreferences`, backed by `shared_preferences`): color,
stroke width, opacity, font size, the stylus/finger mode, and panel
visibility all come back the way the user left them.
Apple Pencil (and any stylus) is first-class for ink: strokes record
pressure and render with variable width, and the first pen contact
turns on palm rejection — fingers scroll while the pen draws. Ink
strokes are smoothed: the sampled points become a Catmull-Rom spline
written as Bézier curves in the appearance stream, so fast strokes
stay rounded instead of showing polyline corners — in this viewer and
any other.
Trackpad gestures behave like the platform's own: a pinch zooms about
the fingers without also scrolling the document (each gesture commits
to scrolling or zooming, whichever its motion shows first), and
sideways flings while zoomed in carry momentum just like vertical ones.
Navigation jumps — search results, links, page thumbnails — land
exactly where they should: the page list is laid out from exact page
geometry rather than scroll estimates (which drift on long documents
with mixed page sizes), and jumping while zoomed in accounts for the
zoom window, placing the target where the user is actually looking.
The viewer opens fitted to the whole page like desktop browser viewers
(`PdfViewer.initialFit`), and draws its own always-visible scrollbar —
high-contrast, outside the zoom transform so it never scales away, with
a draggable thumb and tap-to-jump track; zooming in adds a horizontal
bar for panning the zoom window, and both bars reach the document's
very ends even while zoomed (motion spills from the scroll extents into
the zoom window, like trackpad scrolling).
Dark mode is supported throughout: every widget follows the ambient
Material theme, the canvas around the pages deepens automatically under
a dark theme (override it with `PdfViewer.backgroundColor`), and the
chosen theme mode persists on the device like the other UI preferences
(`PdfEditingPreferences.themeMode`) — the example app has a
system/light/dark toggle in its app bar.
The paper itself can be recolored too: `PdfViewer.pageColor` renders
pages on any background instead of white (sepia for reading, a tint to
match the app) — a pure display setting that leaves the document
untouched, mirrored by the thumbnails and the eyedropper, persisted via
`PdfEditingPreferences.pageColor`, and exposed in the example app
through a color-picker button in the app bar.
The selection model is desktop-grade. With a mouse, selection is the
default mode: clicking an annotation selects it with no tool armed,
dragging empty page area grab-pans the document, and the cursor tells
the story — a pointer over annotations, an I-beam over text, an open
hand over pannable space. Annotations multi-select like desktop apps:
drag a rubber band across them, shift/⌘-click to toggle one in and
out, ⌘A/Ctrl+A to select every annotation on the page (with no select
tool in play it selects the page's text instead). A multi-selection
moves as a group and deletes as a group — one undo step — and while
the select tool is armed, touch drags on empty page area still scroll
the document, so selecting and getting around never fight each other.
Text boxes are written and edited in place, like a desktop editor:
dragging out the free-text tool opens an inline editor right on the
page — same font, size, and color the committed annotation will have —
and tapping an already-selected text box reopens it with its text.
A tap outside (or switching tools) commits; Escape cancels. The font
itself is selectable: Helvetica, Times, or Courier — the classic PDF
standard fonts, written with proper AFM metrics and `/Widths` so every
viewer lays the text out identically — next to the font-size slider in
the style popup, and with a text box selected those controls restyle
it directly (font and size changes re-render the annotation while
keeping its text, position, color, and author). Still
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

The example app (`packages/pdf_flutter/example`) runs on all six Flutter
platforms — macOS, iOS, Android, web, Windows, Linux — with
platform-native file handling: the system picker to open, and a save
dialog, browser download, or share sheet to save, whichever the platform
has.

### Rendering test suite

`test_corpora/ghent/` carries the [Ghent PDF Output Suite
V5.0](https://gwg.org/) — 54 print-conformance PDFs covering overprint,
DeviceN/spot color, ICC v2/v4, 16-bit images, transparency blend modes,
softmasks, optional content, font formats, and JBIG2/JPEG 2000
compression. Two layers run over it:

- `pdf_graphics/test/ghent_corpus_test.dart` interprets every page on
  the plain Dart VM (parse + paint-op assertions, no rasterization).
- `pdf_flutter/test/ghent_render_test.dart` rasterizes every page and
  compares it pixel-wise against checked-in baseline renders;
  regressions dump actual/diff images for inspection, and
  `GHENT_UPDATE=1` re-baselines after an intentional change.
