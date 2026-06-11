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
   /MK decorations), and a full template-editing API — field metadata
   (`describeFields`: name, type, page index, widget rect), creating
   fields on any document, renaming, deleting, retyping
   (`changeFieldType` rebuilds at the same spot, keeping the name),
   image-filled push buttons (`setButtonImage` — the conventional
   carrier for signatures and logos; JPEG or PNG with transparency),
   and fault-tolerant whole-form flattening (`flattenForm`)
10. ✅ Page manipulation: reorder/move, remove, merge with cross-document
    object copying (`appendPagesFrom`), and split (`extractPages` writes a
    standalone file; extracting from an encrypted document decrypts)
11. ✅ Digital signatures: validation (CMS/PKCS#7 with RSA and ECDSA
    P-256/384/521, byte-range and revision-coverage checks; trust-store
    chain evaluation not included) and signing (`saveSigned` —
    adbe.pkcs7.detached, RSA-SHA256, verified interoperable with
    OpenSSL and poppler)
12. ✅ Content editing tiers: stamping (`stampPage` — text, shapes,
    JPEG and PNG images over existing content; PNG decoding is pure
    Dart and alpha becomes a soft mask), element deletion
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
author shown; tapping a tile zooms the viewer to the annotation, a
long press starts multi-select for deleting a whole set as one
undo step, and a search field at the top filters the list live by
type, author, contents, field name or value, and link text or
target), an annotation properties panel
(`PdfAnnotationPropertiesPanel` — shows the selection's type, page,
color, fill, stroke width, opacity, font, contents, author, and
position/size in page points, and every one of those is editable in
place: swatches open the color picker, sliders restyle on release,
text fields commit on enter or focus loss, and the geometry fields
move or resize the annotation numerically; with several annotations
selected the style controls act on all of them at once), a page
thumbnail sidebar
(`PdfThumbnailSidebar` — tap to jump, drag to reorder pages, delete,
with a live viewport indicator), a full-spectrum color picker with an
eyedropper that samples colors from the rendered page — with a live
swatch-and-hex preview riding beside the pointer
(`PdfColorPicker`), and a ready-made `PdfEditingToolbar`.
The picker's value row speaks the standard color formats: hex, RGB,
HSL, and CMYK (a plain device conversion for print-minded entry),
switchable in place, with the channel fields, the spectrum area, and
the swatch all live-synced both ways — and the chosen format persists
on the device, so the picker reopens the way the user thinks about
color.
A signature tool rounds out the annotation suite: draw a signature
once in a pad dialog (`showPdfSignatureDialog` — pressure-sensitive,
like the ink tool), and tap pages to stamp it as an Ink annotation;
the signature is saved on the device and reused across documents and
sessions. Custom rubber stamps work the same way: author a
caption-and-color stamp once in the stamp picker, and from then on a
tap places it — the collection is saved on the device.
Interactive forms are first-class in the viewer too: a form tool
fills fields in place (text fields open an inline editor over the
widget, check boxes and radio buttons toggle on tap, choice fields
drop down their options, and push-button fields fill with an image
through a host-supplied picker — the signature/logo flow), drags out
new fields on empty page area (text, check box, or image button), and
right-clicks fields for rename, convert-to-another-kind, delete, and
whole-form flattening — the template-editing API surfaced as direct
manipulation. UI preferences persist on the device by default
(`PdfEditingPreferences`, backed by `shared_preferences`): color,
stroke width, opacity, font size, the stylus/finger mode, and panel
visibility all come back the way the user left them.
Apple Pencil (and any stylus) is first-class for ink: strokes record
pressure and render with variable width, and the first pen contact
turns on palm rejection — fingers scroll while the pen draws. Pen and
drawing-finger strokes start the instant the pointer touches the page
(no gesture-recognizer latency eating the start of a line), a quick
tap lands as a dot — handwriting keeps its i-dots and punctuation —
and stray palm contact never cancels a pen stroke, while a deliberate
second finger does cancel an accidental one. Ink strokes are
smoothed: the sampled points become a Catmull-Rom spline written as
Bézier curves in the appearance stream, so fast strokes stay rounded
instead of showing polyline corners — in this viewer and any other.
The eraser is a PSPDFKit-style circle eraser that *slices* ink: it
removes exactly the parts of strokes inside the swept circle, splitting
a stroke into pieces where the eraser crosses it (pressure-variable
widths survive the cut), and an annotation only disappears once every
stroke is gone. A ring cursor shows the eraser's true size at any zoom,
the live preview fades the original and paints the exact remainder, one
swipe is one undo, the radius is adjustable from the style menu (and
persists), and a flipped pencil erases while the ink tool is armed. Touch pinch zoom works everywhere — including with a tool
armed — and touch or stylus selections get a floating action chip
(delete, context menu, edit text) standing in for hover and
right-click.
Touch text selection works the platform's way: drags always scroll
(they never get caught starting a selection), a long press selects
the word under the finger and extends by whole words while the press
drags, and lifting shows draggable lollipop handles at both ends plus
a floating Copy/Select-All chip — so highlighting on a tablet is
long-press, adjust the handles, tap the markup button. The handles
counter-scale with zoom (constant size on screen) and their color is
themable (`PdfViewerThemeData.selectionHandleColor`).
Trackpad gestures behave like the platform's own: a pinch zooms about
the fingers without also scrolling the document (each gesture commits
to scrolling or zooming, whichever its motion shows first), and
sideways flings while zoomed in carry momentum just like vertical ones.
Navigation jumps — search results, links, page thumbnails — land
exactly where they should: the page list is laid out from exact page
geometry rather than scroll estimates (which drift on long documents
with mixed page sizes), and jumping while zoomed in accounts for the
zoom window, placing the target where the user is actually looking.
Reusable navigation chrome rounds that out: `PdfPageNumberField` is
the classic "3 / 12" indicator with the page number editable — type a
number and enter to jump there (out-of-range clamps, junk snaps back);
`PdfSearchField` is a slim, app-bar-sized search box that searches as
you type, with the match count, previous/next, and clear riding
alongside; and `PdfSearchResultsPanel` lists every hit with the text
around it, grouped by page — the current match highlighted, a tap
jumps to it, and the panel resizes like the sidebars with its width
persisted (`PdfEditingPreferences.searchPanelWidth`). Underneath,
`PdfViewerController.searchResults` exposes each match with its
context snippet and `goToMatch` jumps to any of them, so custom
results UIs need no extra plumbing.
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
Beyond that, the whole viewer chrome is themable: wrap any subtree in
`PdfViewerTheme` and `PdfViewerThemeData` recolors the canvas, the
text-selection and search-match highlights, the editing overlay's
selection chrome (annotation boxes and handles, the content tool's
element chrome, the zoom-to attention flash), and the scrollbars
(`PdfScrollbarThemeData`). The viewer-style scrollbar is itself a
reusable widget (`PdfScrollbar`) and both sidebars use it in place of
the platform's implicit bar, so every scrollbar in the chrome shares
one look — themed together, readable in light and dark mode alike.
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
Annotation interactions have desktop-app polish. Resizing behaves like
a vector editor, not an image stretcher: squares, circles, and text
boxes regenerate their appearance at the new size, so a stretched
rectangle keeps its line weight and a widened text box re-wraps its
text at the same font size (free text round-trips its background fill
and border through the dictionary for the same reason — text edits
keep them too). A text box's resize *preview* re-wraps live as well:
the drag shows the text re-flowing at its committed size, never
stretched glyphs. The selection chrome
follows a rotated annotation — box, knob, and all spin with the artwork
instead of boxing its axis-aligned bounds, and the next rotate drag
snaps the *total* angle to 45° steps, so a rotated annotation clicks
back to square. Rotated annotations resize too: the handles ride the
spun chrome and drag along the annotation's own axes (the live preview
scaling with them), so rotated artwork grows and shrinks without ever
shearing — and the resize is anchored like any vector editor's: the
geometry opposite the drag stays planted on screen and the dragged
handle tracks the pointer exactly, whatever the rotation. The chrome itself is zoom-invariant: outline, handles, and
the rotate knob stay the same size on screen however far in you zoom,
like any desktop editor's selection handles (and the knob's connector
line tucks under the top handle instead of crossing it out).
Edits never flash: when a commit lands, the overlay
keeps the committed preview painted (the moved annotation's artwork at
its new place, the just-drawn ink, the typed text) until the page's
re-render actually reaches the screen, so nothing blinks out for a few
frames the way most viewers do. Ink commits itself — strokes drawn in
quick succession aggregate (dot an i, cross a t) and the drawing lands
as one annotation, one undo step, about a second after the pen lifts;
no confirm button (set `inkCommitDelay` to null for the old manual
flow). And the signature tool shows the signature riding the pointer —
hover with a mouse, press-and-drag on touch — at exactly the size and
position a tap or release will stamp.
Right-clicking an annotation opens a context menu (two-finger tap on a
trackpad): copy, cut, paste, bring to front, send to back, delete.
Z-order edits reorder
the page's /Annots array — the PDF's painting order — so they stick in
any viewer; a multi-selection moves as a block keeping its internal
order, the menu entries disable when they'd change nothing, and the
selection follows the annotations to their new slots. Apps extend the
menu through `PdfViewer.annotationMenuBuilder`: return
`PdfAnnotationMenuItem`s and they appear below a divider, each handed
the selection it acts on (the example app adds "Copy text" for
annotations that carry any).
Copy, cut, and paste work the way a vector editor's do — ⌘C/⌘X/⌘V (or
Ctrl) and the context menu. Copies are deep snapshots of the
annotation and its appearance, detached from any document, so they
survive edits, undo, and even switching files: paste onto another
page, after undoing the original away, or into a different document
entirely. Pasting from the menu drops the copy centered on the
right-click point (an empty-area right-click offers paste alone);
pasting with the keyboard keeps the position, stepping each repeat
12pt down-right so copies don't stack invisibly — and everything
clamps to stay on the page. A paste selects what it pasted, and a
multi-annotation paste is one undo step.
Any authored annotation restyles in place: with shapes, ink, markups,
notes, stamps, or text boxes selected, the palette recolors them and
the stroke-width and opacity sliders show — and change — the
selection's own values, committing one revision per slider release.
Restyling regenerates the appearance at the current geometry (ink
keeps its pressure-variable widths, highlights keep their Multiply
blending, rotated artwork keeps its turn), and because the rewrite
keeps object numbers, the selection, z-order, author, and comments
all survive. Free text maps the palette color to its text color, with
fill and border still on their own swatch rows.
Fast scrolling stays smooth on heavy documents: pages flying past
during a fling defer their first interpretation — the expensive part
of rendering — until the scroll settles, showing the paper color
meanwhile, the way desktop browsers blank pages mid-fling. Without
that, a dense CAD page entering the viewport could stall the UI for
hundreds of milliseconds and the scrollbar visibly leapt; with it,
the fling glides and the pages fill in the moment the view comes to
rest (slow scrolling still renders continuously — the hold only
engages past about two viewport-heights per second).
The scrollbar itself is rock-steady on documents that mix page sizes:
the viewer's list reports exact scroll metrics computed from the real
page heights instead of the framework's running estimate, which on a
291-page spec with landscape drawings interleaved would otherwise
swing by tens of thousands of pixels mid-scroll and make the thumb
jump around the track.
The side panels are desktop-grade too. All three panels resize by
dragging their inner edge (the chosen widths persist on the device
with the other UI preferences), all keep their content clear of the
overlay scrollbar's lane (no bar over a delete button), the thumbnail
strip follows the
viewer — scrolling, search hits, and link jumps bring the current
page's tile into view — and tapping an annotation in the list pulses
an amber attention ring around it on the page, so the eye lands on
the right spot after the zoom. The strip is also built for large
documents: thumbnails are rasterized at tile resolution into an LRU
cache keyed by a per-page render stamp, so an edit (or undo) only
re-renders the pages it actually touched, renders run one page at a
time instead of bursting on first layout, and scrolling the viewer
repaints only the little viewport indicators — never the page images.
The annotation list reads like an inspector: form-field tiles show
the field's kind (text, button, choice, signature), its fully
qualified name, and its current value; link tiles show the text the
link covers on the page and where it goes — the URI, the target page,
or the named action.
Text boxes are written and edited in place, like a desktop editor:
dragging out the free-text tool opens an inline editor right on the
page — same font, size, color, and background the committed annotation
will have, its content area pixel-aligned with the box so the text
doesn't shift when editing starts, focused and ready to type the
moment it opens — and tapping an already-selected text box reopens it
with its text.
A tap outside (or switching tools) commits; Escape cancels. The font
itself is selectable: Helvetica, Times, or Courier — the classic PDF
standard fonts, written with proper AFM metrics and `/Widths` so every
viewer lays the text out identically — next to the font-size slider in
the style popup, and with a text box selected those controls restyle
it directly (font and size changes re-render the annotation while
keeping its text, position, color, and author). Text boxes also take a
background fill and a border, right from the style popup: two swatch
rows (none / palette / custom color) set the defaults new boxes are
created with — persisted with the other preferences — and restyle the
selected box in place; the border's weight follows the stroke-width
slider. Still
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

It opens onto a generated six-page feature showcase: PDF link/JavaScript
actions driving the Flutter app and live widgets pinned onto the page
(both directions of interactivity), then a vector-graphics page (dashes,
joins, Bézier fills, stitched axial and radial shadings, blend modes,
constant alpha, CMYK/gray swatches), a typography page (the standard
fonts, rendering modes, spacing/scaling operators, text transforms), an
images page (RGB XObjects, color-key masks, 1-bit stencils, inline
images), and an annotations & forms page whose markup, shapes, stamp,
note, and filled form fields are authored through the editor API while
the document is generated — the demo doubles as a smoke test of the
authoring pipeline.

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
