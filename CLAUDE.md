# dart-pdf — pure-Dart PDF renderer & editor

Monorepo using **pub workspaces** (root `pubspec.yaml` lists members under
`packages/`). Flutter is managed with **fvm** (see `.fvmrc`); use
`fvm flutter` / `fvm dart`, or the binaries in `~/fvm/versions/3.44.0/bin/`.

## Commands

- `fvm flutter pub get` (at repo root — resolves every workspace package)
- `fvm dart analyze` (at root)
- `cd packages/<pkg> && fvm dart test` (pure-Dart packages)
- `cd packages/pdf_flutter && fvm flutter test`

## Layering rules (strict)

`pdf_cos` ← `pdf_document` ← `pdf_graphics` ← `pdf_flutter`

- `dart:ui` and Flutter imports are **only** allowed in `pdf_flutter`.
  Everything else must run on the Dart VM (server/CLI/tests) and on the web.
- `dart:io` is not allowed anywhere in `lib/` (web support); use
  `package:archive` for compression.
- `pdf_cos` knows nothing about pages or rendering — only the COS object
  model, syntax, filters, xref, and (de)serialization.

## Design conventions

- Parsers are lenient on input (real-world PDFs are broken: wrong /Length,
  missing endobj, junk before header) and strict on output.
- Streams stay as raw byte views (`Uint8List.sublistView`) until decoded;
  objects load lazily through the xref.
- `CosDictionary` is keyed by `String` (name without the slash).
- Test fixtures are built programmatically in `test/fixtures.dart` so byte
  offsets are always correct — don't hand-edit offsets.

## Test corpus

`corpus/` (git-ignored) holds ~50 real-world PDFs copied from Ben's local
folders and OneDrive — CAD drawings, scanned docs, reports, forms. Use them
to validate changes:

- Parse check: `cd packages/pdf_document && fvm dart tool/inspect.dart ../../corpus/*.pdf`
- Render check: `cd packages/pdf_flutter && PDF_PATH=../../corpus/<file>.pdf PDF_PAGE=0 fvm flutter test test/render_smoke_test.dart` (writes /tmp/dart_pdf_render.png)

`test_corpora/ghent/` (checked in) is the Ghent PDF Output Suite V5.0 —
54 print-conformance PDFs (overprint, DeviceN, spot, ICC v2/v4, 16-bit,
transparency blend modes, softmasks, optional content, font formats,
JBIG2/JPX) incl. 3 composite test pages. Two test layers:

- `packages/pdf_graphics/test/ghent_corpus_test.dart` — pure-Dart: every
  page must interpret without throwing and paint > 0 ops.
- `packages/pdf_flutter/test/ghent_render_test.dart` — rasterizes every
  page and diffs against checked-in baselines in
  `test_corpora/ghent/_baselines` (fail when >0.05% of pixels differ by
  >8/channel). Missing baselines seed on first run; accept intentional
  rendering changes with `GHENT_UPDATE=1 fvm flutter test
  test/ghent_render_test.dart`. Mismatches dump actual+diff PNGs to
  `test_corpora/ghent/_failures/` (git-ignored). The baselines pin
  current behavior, not GWG conformance — many patches print their own
  pass criterion on the page (overprint simulation isn't implemented;
  GWG173's faint "X" is a known JBIG2 deviation).

## Roadmap context

See README.md. The pipeline through the viewer is done: interpreter, font
engine, Flutter rendering, text selection/search, annotation appearance
rendering, and encryption both ways (RC4/AES-128/AES-256 decryption;
encrypt-on-write re-encrypts changed objects on save — `_encryptedCopy`
in updater.dart; signing encrypted files stays refused). Annotation authoring is in:
`PdfEditor` creates highlights/ink/shapes/free text/notes/stamps with
generated appearance streams (`annotation_editor.dart`) and can flatten
them into page content. AcroForm support is in: `PdfAcroForm`/`PdfFormField`
model (`form.dart`) plus filling with regenerated appearances
(`form_editor.dart` — text/checkbox/radio/choice, auto-size, quadding).
Page manipulation is in (`page_editor.dart`): reorder/move/remove flatten
the page tree (materializing inherited attributes), `appendPagesFrom`
deep-copies pages across documents, `extractPages` splits into a fresh
file via `CosDocumentBuilder` (pdf_cos's from-scratch writer).
Digital signatures are in: `PdfSignature.of(doc)` + `validate()`
(`signature.dart`; CMS/X.509/RSA/ECDSA primitives live in
`pdf_cos/src/crypto/` — asn1, rsa, ecdsa, cms) and `PdfEditor.saveSigned`
(`signature_editor.dart`, adbe.pkcs7.detached with ByteRange patching).
No trust-store chain validation. Test signer identity in
`pdf_test_fixtures/src/signer_identity.dart`.
Content editing is in: `PdfEditor.stampPage` (text/shapes/JPEG via
`PdfStamp`), `PdfPageElements.of` + `PdfEditor.deleteElements` (element
enumeration with approximate bounds, stream rewriting), and
`PdfEditor.replaceText` (simple fonts only) — all in
`content_editor.dart`/`content_elements.dart`; the content-stream
tokenizer (`ContentStreamParser`) now lives in pdf_cos.
The roadmap is complete. Polish landed since: LZW/RunLength filters, xref recovery
(`CosDocument.open` falls back to scanning for `N G obj` when the xref
chain is broken), type 4 PostScript calculator functions, /Count-based
page lookup with full-walk fallback, gradient /Extend semantics, JPEG
/Decode + color-key masks, and /Rotate folded into `PdfPageGeometry`
(selection, highlights, overlays, and hit-testing are rotation-aware;
the geometry mirrors the renderer's canvas transform).
The big-gap batch landed next, all KAT-validated against reference
codecs: encrypt-on-write (updater `_encryptedCopy`; signing encrypted
files still refused), trust-store chain validation
(`verifyCertificateChain` in pdf_cos cms.dart, `PdfTrustStore` +
`validate(trustStore:)` in pdf_document), mesh shadings 4-7
(`PdfMeshParser`/`PdfMesh`, device `fillMesh`, drawVertices in
pdf_flutter), CCITT G3/G4 (`CcittDecoder`, KAT vs libtiff), JBIG2
embedded profile (`Jbig2Decoder` + shared `MqDecoder` in
filters/mq.dart, KAT vs jbig2enc/jbig2dec), JPEG 2000 (`JpxDecoder`,
lossless bit-perfect vs OpenJPEG, lossy ±1), deep-zoom detail patch
(`PdfPageView` renders the visible slice past the raster caps;
`rasterizeRegion`), and real ICC (`IccProfile` in pdf_graphics —
gray TRC, matrix/TRC, mft1/mft2/mAB LUTs, validated vs littleCMS;
wired into sc/scn and image decoding). Remaining gaps: text reflow,
RSASSA-PSS, JBIG2 Huffman/refinement, JPX subsampling + PCRL/CPRL,
rendering intents/BPC in ICC.
The editing UI is in (pdf_flutter `src/editing/`): `PdfEditingController`
owns the edit session — every edit is an incremental save, so revisions
are byte prefixes of one buffer and undo/redo is a stack of lengths;
`PdfViewer(editing:)` injects per-page tool overlays (markup/ink/shapes/
free text/note/stamp; select + move + resize via
`PdfEditor.resizeAnnotation`, which rewrites /Rect and scales the point
arrays — appearances stretch per §12.5.5), binds undo/redo/delete/escape
shortcuts, and preserves the viewport across same-geometry document
swaps. `PdfEditingToolbar` is the stock chrome. The host must rebuild
the viewer with `editing.document` whenever the controller notifies
(asserted in debug builds); the example app shows the wiring.
On top of that: style controls (controller carries strokeWidth/opacity/
fontSize; the toolbar's tune button opens a slider popup), an
annotation sidebar (`PdfAnnotationSidebar` — lists by page, tap selects
via `selectAnnotation(page, slot)`, trailing delete), and a content
tool (`PdfEditTool.content`: taps hit-test `PdfPageElements` — cached
per revision in the controller — orange selection chrome; delete via
`deleteElements`, text rewrite via `replaceText`; element ids die with
every revision, so any edit clears the element selection).
Page management UI: `PdfThumbnailSidebar` (editing_thumbnails.dart) —
display-list thumbnails (`renderPicture` replayed scaled, no
rasterization), tap to jump, long-press drag to reorder
(ReorderableListView `onReorderItem` — already index-adjusted), footer
delete; `controller.movePage`/`removePage` clear the slot-based
annotation selection first because page indices shift under it, and
`removePage` is a no-op on the last page. Reorder drag: immediate for
mouse pointers, long-press for touch (custom listener picking the
recognizer per pointer kind). The strip shows a viewport indicator fed
by `PdfViewerController.visiblePageRegion(page)` (fractions 0–1) and
repainted via `viewportChanges` (a separate Listenable so scrolling
doesn't spam controller listeners). `PdfViewer.initialFit` defaults to
`PdfViewerFit.page` (whole first page visible, Chrome-style) — widget
tests that do view-coordinate math pin `initialFit: PdfViewerFit.width`.
Color + stylus round: `PdfColorPicker`/`showPdfColorPicker`
(editing_color_picker.dart — HSV area, hue slider, hex field; opaque
colors only, opacity stays a controller property) and an eyedropper:
`controller.startColorPick()` arms it, the page overlay's next tap
samples via `PdfPageRenderer.sampleColor` (3×3-point patch through
`rasterizeRegion`+`toByteData`; view→raster is position/geometry.scale)
and calls `finishColorPick` (forced opaque). The overlay is injected
when `tool != null || isPickingColor`, so `_tool` is nullable there;
Escape cancels picking first. Apple Pencil: ink strokes carry per-point
normalized pressure (raw `Listener` feeds `_pointerPressure`, since pan
callbacks drop it; null when pressureMax == pressureMin, i.e. finger/
mouse — uniform width). `addInk(pressures:)` writes one stroked segment
per point pair at `pdfInkStrokeWidth(base, p)` = base×(0.4+1.2p) (round
caps hide seams; InkList stays the centerline; rect pads by the widest
point). Palm rejection: first stylus down with ink armed flips
`controller.fingerDrawsInk` false → GestureDetector `supportedDevices`
excludes touch, so fingers scroll under the overlay (toolbar touch_app
button toggles back). Test gotchas: TestGesture can't set pressure —
dispatch raw PointerDown/Move/Up via tester.binding.handlePointerEvent
(supply delta); the eyedropper's toImage needs `tester.runAsync` after
the tap (poll isPickingColor with real delays).
Eyedropper preview (from Ben's feedback): `PdfPageColorSampler`
(renderer.dart) rasterizes a page once (1px/pt) and answers `colorAt`
lookups from the cached ByteData — per-event re-rendering would be far
too slow; `sampleColor` is now the one-shot wrapper. The overlay keys
the sampler on document identity, previews on hover (mouse) and
down/move (touch/pencil) via a floating swatch+hex chip
(`_EyedropperChip`, cleared on MouseRegion exit), and commits from the
raw pointer-up (so tap and press-drag-release both pick; the tap
handler no-ops while picking). dart:typed_data must be imported
explicitly for ByteData (flutter/painting doesn't re-export it).
Persisted UI preferences (Ben: save them locally, default behavior):
`PdfEditingPreferences` (editing_preferences.dart, backed by
shared_preferences, keys `pdf_flutter.editing.*`) — color/strokeWidth/
fontSize/opacity/fingerDrawsInk plus host-chrome flags
showThumbnailSidebar/showAnnotationSidebar. The controller's style
state proxies to it (no duplicate fields; `preferences.addListener(
notifyListeners)` in the ctor, removed in dispose); each controller
creates its own instance by default, the example app shares one
(`preferences:` param) so panels persist too. Loading is async
(`ready`); when storage is missing (widget tests) getInstance throws,
it's swallowed, defaults stand, writes no-op — so plain tests stay
deterministic with zero mocking. A setter call during the in-flight
load wins over stored data (`_modified` guard). Persistence tests use
`SharedPreferences.setMockInitialValues` + `pumpEventQueue()` before
reading back (writes are unawaited).
Signature tool (editing_signature.dart): `PdfInkSignature` stores
strokes normalized 0–1 (y-down) + aspect + RGB color + optional
pressures, JSON-encoded into preferences (`signature` slot).
`PdfEditTool.signature` is tap-driven: `placeSignature(page, x, y,
width: 160)` maps normalized→page space (y-flip), clamps center so the
whole thing stays in the crop box, strokeWidth = w/75, commits via
addInk (so pressure-variable width and select/move/resize come free).
Toolbar history_edu button opens `showPdfSignatureDialog` first when
no signature is saved, then arms; restart_alt redraws while armed. Pad
key: ValueKey('pdf-signature-pad'). Test gotcha: scrollUntilVisible
needs `scrollable:` scoped to the toolbar once a viewer is in the tree
(two Scrollables otherwise). Example app: ⌘F/Ctrl+F focuses search via
CallbackShortcuts wrapping the Scaffold (shortcuts bubble up the focus
tree from the viewer's focus node).
Custom stamps (editing_stamps.dart, Ben's ask): `PdfCustomStamp`
(caption + RGB color, JSON) — saved list persists via preferences
`customStamps` (a string-list key, one JSON blob per stamp).
`controller.activeStamp` is transient (each session starts in the
classic type-the-caption flow); with one set, a stamp-tool tap calls
`placeStamp(page, x, y, height: 40)` — width mirrors addStamp's
appearance math (measureHelvetica bold + 24pt padding) so the caption
isn't shrunk, center-clamped to the crop box like placeSignature.
Drag-out still works and uses the active stamp's text/color; with no
active stamp it prompts as before. Toolbar: a `style` icon button
('Custom stamps…') appears while the stamp tool is armed →
`showPdfStampPicker` (tap to select, trailing delete, 'New stamp…' →
`showPdfStampEditor`, text field key 'pdf-stamp-text'; the 'Type the
text for each stamp' tile clears activeStamp). Deleting the active
stamp also clears it.
Live drag preview (Ben's ask): moving/resizing a selected annotation
shows its real appearance at the dragged rect, Acrobat-style — the
original stays rendered, a ~75% ghost rides the drag.
`PdfInterpreter.drawAnnotation(page, annotation)` (single-annotation
slice of drawAnnotations) + `PdfPageRenderer.renderAnnotationPicture`
(appearance alone, page raster space, transparent bg, null without an
/AP). The overlay caches the picture per (document, page, slot) —
`_ensureGhost()` from build, so it's ready before the drag — and the
painter calls `paintAnnotationDragPreview` (public in
editing_overlay.dart, @visibleForTesting): saveLayer 0xBF alpha,
translate/scale from the resting view rect onto the preview rect (the
same §12.5.5 stretch resizeAnnotation commits). Tests in
editing_drag_preview_test.dart; the mid-drag pixel check captures a
RepaintBoundary via tester.runAsync(toImage) while the gesture is held.
Annotation rotation: `PdfEditor.rotateAnnotation(page, annot, degrees)`
(annotation_editor.dart) — degrees CCW about the rect center; bakes the
current BBox→Rect fit into the appearance /Matrix (no shear when BBox
aspect ≠ Rect), concats the rotation, then sets /Rect to the BBox
corners' bounds under the *new* matrix (the matrix carries the whole
rotation history, so 45°+45° lands exactly where 90° does — never
compute the rect from the old rect's dims). Point arrays
(QuadPoints/InkList/L/Vertices/CL) rotate jointly via _mapPointPairs.
UI: rotate knob 22px above the selection's top-center
(editing_overlay.dart; resize handles win the overlap), drag sweeps
about the center with 45°-multiple snap (±3°), ghost + chrome spin live
(paintAnnotationDragPreview takes `rotation`), commit flips sign —
view clockwise = page −CCW: `rotateSelected(-delta*180/pi)`.
`canRotateSelected` = resizable subtype + has /AP. Tests:
annotation_editor_test.dart (matrix/rect/ink math, 45+45≡90),
editing_rotate_test.dart (pixels + handle-drag sign chain).
Annotation list round (zoom-to, multi-select delete, authors):
`PdfViewerController.showRect(page, rect)` frames a page rect —
`_showRect` centers it and zooms to ~40% viewport fill, clamped
[1, maxZoom] (never zooms out); the transform translation is solved
against the clamped scroll offset, and both clamp at document edges,
so near-margin rects sit off-center (tests frame mid-page rects).
Sidebar (now stateful): tap zooms + selects; long-press enters
multi-select (checkboxes, header 'N selected' + delete) committed via
`controller.deleteAnnotations(slots)` — annotations are all resolved
before the first removal (slots shift), one apply = one undo, clears
the annotation selection; checked state dies with every revision
(document-identity check in build). `PdfAnnotation.author` reads /T
(ignored for Widgets, where /T is the field name);
`controller.author` (persisted preference `author`) stamps /T on all
ten creation paths and is preserved across setSelectedText's
remove+re-add. Tile subtitle is 'author — contents'. Example app:
person_outline AppBar button prompts for the name. Tests:
editing_sidebar_test.dart.
Ink smoothing (Ben: "curves looked chunked"): points are sampled once
per frame, so fast strokes left long straight `l` segments.
`pdfInkCurveControls(points)` (annotation_editor.dart, exported beside
pdfInkStrokeWidth) converts a polyline to Catmull-Rom cubic controls —
c1 = pᵢ + (pᵢ₊₁−pᵢ₋₁)/6, c2 = pᵢ₊₁ − (pᵢ₊₂−pᵢ)/6, neighbors clamped at
the ends; two points degenerate to a straight chord. `addInk` writes
`c` ops (per-pair moveTo+curveTo for pressured strokes), and the rect
bounds include the control points (a spline can overshoot its samples;
the Bézier hull makes the pad rigorous — covered by the "spline
overshoot" test). The same helper drives the live previews so drawn ==
committed: overlay `_EditingPreviewPainter` (cubicTo; controls computed
in page space then mapped — affine, order irrelevant) and the signature
pad painter. /InkList still stores the raw samples per spec.
