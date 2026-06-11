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
Scrollbars (Ben: "very hard to see"): the implicit desktop bar lived
inside the InteractiveViewer (thin, scaled away when zoomed) — now
suppressed via ScrollConfiguration(scrollbars: false). `_PdfScrollbar`
(pdf_viewer.dart, axis-generic) paints outside the transform in the
canvas Stack: light thumb + dark outline (reads on dark canvas and
white pages), faint track scrim, hover/drag widens 8→10px, min thumb
36px, DragStartBehavior.down, track tap/track-grab jumps then drags.
Vertical position = scroll.pixels − t_y/s (the transform unprojection);
motion goes through `_scrollbarScrollBy`, which spills what the scroll
extents can't absorb into the zoom window (trackpad-style) so the ends
stay reachable zoomed. Hidden while range ≤ pageSpacing (the list's
bottom padding is nominal slack). Horizontal bar appears only zoomed
(sideways overflow lives in the transform; `_scrollbarPanBy` pans
m[12]), inset right by hitExtent(14) so corners don't collide; needs
`viewExtent: _viewWidth` since its own track is inset. Thumb keys:
'pdf-scrollbar-thumb' / 'pdf-hscrollbar-thumb'. Test gotchas
(pdf_scrollbar_test.dart): lazy-ListView maxScrollExtent is an
estimate that drifts as items build (tolerances, not exact math);
tester.drag eats touch slop (use startGesture+moveBy); touch taps on
the bar resolve only after the viewer's double-tap timeout (pump
400ms); end drag tests with a 300ms pump for the scroll-settle timer.
Dark mode: all chrome follows the ambient Material theme. The viewer
canvas is theme-aware — `PdfViewer.backgroundColor` overrides; default
is 0xFF404347 (light themes, the historical slate) or 0xFF202124
(dark), resolved in build before the LayoutBuilder. Swatch/preview
borders that were Colors.black26 (toolbar palette, signature pad +
inks, stamp inks, color-picker preview, eyedropper chip) now use
colorScheme.outline so they read on dark surfaces; pads/pages stay
paper-white on purpose. `PdfEditingPreferences.themeMode` (ThemeMode,
key `themeMode`, stored by name) is a persisted host-chrome pref; the
example app's MaterialApp listens to the prefs for themeMode (ViewerApp
is now stateful and owns the prefs instance, passing it to
ViewerScreen) with an AppBar button cycling system→light→dark. Test
gotcha (dark_mode_test.dart): re-pumping MaterialApp with a new theme
animates via AnimatedTheme — a single pump still reads the old
brightness, so assert light and dark in separate tests.
Page color (Ben: "instead of a white page it must be blue or green or
another arbitrary colour"): the paper is just the fill renderPicture
paints under the content, so `PdfPageRenderer.renderPicture/renderImage/
sampleColor/PdfPageColorSampler.of` take `pageColor` (default white) and
`PdfViewer.pageColor` threads it through _PdfViewerPage → PdfPageView
(placeholder ColoredBox matches; didUpdateWidget drops the cached
picture on color change) and into EditingPageOverlay so the eyedropper
raster matches what's on screen (sampler keyed on document AND color).
`PdfThumbnailSidebar.pageColor` does the same for thumbnails. Display
setting only — the document is untouched. Persisted as
`PdfEditingPreferences.pageColor` (int key `pageColor`); the example app
has a format_color_fill AppBar button → showPdfColorPicker, wiring the
pref into both the viewer and the thumbnail strip. Test gotcha
(page_color_test.dart): page renders complete without runAsync in
widget tests — placeholders are already replaced after a pump, so
assert on the RawImage/RepaintBoundary pixels (poll with runAsync
delays), not on placeholder ColoredBoxes.
In-place text (Ben: write in place, edit after creation, font + size):
`PdfStandardFont` (pdf_cos-free, content_writer.dart) — Helv/TiRo/Cour
resource names, BaseFont, per-font ascent, AFM widths (new
`timesRomanWidths`; Courier is flat 600), `measureStandardText`, and a
lenient `fromName` (Times*/serif→times, Cour*/mono→courier, else
helvetica). `addFreeText(font:)` threads it through wrap, baseline,
/DA, and the resource dict (`_standardFont`/`_fontResource` generalize
the old `_helvetica`, which stays for bold stamps). Controller:
`fontFamily` (persisted pref key `fontFamily`, stored by enum name),
`selectedTextStyle` (/DA parse `/(\S+) (\d+) Tf`),
`restyleSelectedText(font:,size:)`; it and `setSelectedText` share
`_rewriteSelected` (remove+re-add, re-selects the last /Annots slot so
consecutive restyles stay anchored). `isEditingText`/`setEditingText`
gate the viewer: CallbackShortcuts binds {} and the pointer-down
focus-steal is skipped while typing — otherwise backspace deletes the
selected annotation and any click closes the editor. Overlay: a
free-text drag-out or a tap on the already-selected FreeText opens an
inline TextField (key 'pdf-freetext-editor') over the view rect,
styled fontSize×scale, height 1.2, family mapped like canvas_device's
substitution (Helvetica/Times New Roman/Courier); outside tap, drag,
or tool switch commits, Escape cancels via the editor's own
CallbackShortcuts (nearer to the focus, so it wins); editing existing
text washes pageColor at 0.92 alpha over the old rendering. Toolbar
`_StyleMenu` (now stateful): Sans/Serif/Mono SegmentedButton + the
size slider show the selected free text's style and restyle it on
change end (one revision per slider gesture, `_draggingFontSize`
carries the thumb meanwhile); tooltip renamed 'Stroke, opacity,
font'. Test gotchas (editing_text_edit_test.dart): tap targets must
stay inside the 800×600 test viewport — view(500,300) is y≈643px, the
tap silently misses; the SharedPreferences mock store is
process-global, so widget tests call setMockInitialValues({}) before
creating controllers or a prior test's stored fontFamily leaks in
through the async preference load.
Gesture/navigation fixes (session 3 of batch 2): trackpad gestures
latch an intent per gesture (`_TrackpadIntent` in pdf_viewer.dart) —
macOS reports finger drift as pan deltas during a magnify gesture, so
the first signal past its threshold (|scale−1| > 0.01 → zoom, 8px
accumulated pan → scroll) claims the whole gesture; pre-latch motion
is paid back in one piece when scroll latches, and pinch lift-offs
never fling. Horizontal momentum: `_panFlinger` (unbounded
AnimationController + FrictionSimulation 0.0000135, InteractiveViewer's
drag) continues the zoom window's x-translation after lift-off,
clamped at the edges; stopped on pointer down, wheel, and new trackpad
gestures (State is now TickerProviderStateMixin — two tickers). Jump
accuracy: the ListView gets `itemExtentBuilder` (exact per-page
extents, so scroll extents/offsets never drift from estimates on long
mixed-size docs — `buildVariedHeightPdf` in pdf_test_fixtures cycles
792/396/1008pt pages to defeat uniform estimates), and `_jumpToPage` /
`_scrollToDestination` / `_showMatch` add `_zoomWindowDy` (= t_y/s):
zoomed in, the screen sees list space through (p − t)/s, so targets
shift by t_y/s — _showMatch also scales its viewport-third to
viewH/(3s). Test gotchas (pdf_viewer_test.dart): panZoomUpdate's `pan`
is cumulative, not a delta; widget tests can't reproduce the lazy-list
estimate drift (animateTo lays pages out continuously, so the
zoomed-search test is the regression gate for jump accuracy — it
fails by t_y/s ≈ 240px un-fixed).
Multi-platform example (Ben: "make sure the example runs on all
platforms"): the example app has shells for all six platforms (ios/
android/web/windows/linux generated with --org dev.milanko alongside
the original macos). main.dart is dart:io-free: open uses XFile
(readAsBytes + file.name), the type filter carries extensions +
mimeTypes + uniformTypeIdentifiers (each platform throws without its
field), and _saveAs branches — desktop getSaveLocation+saveTo, web
XFile.fromData(...).saveTo (browser download), mobile share_plus
(ShareParams files+fileNameOverrides+sharePositionOrigin; the origin
rect is required on iPad). Demo overlays pin to slots via _slot
(FittedBox + SizedBox at PDF-point design size) so they scale with the
page — the counter Row overflowed its slot at fit-page scale. Verified
builds: web, macOS, debug APK, iOS simulator. Example test gotchas:
the example's tests derive the page rect from the viewer's fit-page
math (viewer rect → zoom = h/(w·aspect), centered) instead of assuming
fit-width; toolbar taps need scrollUntilVisible scoped to the
toolbar's Scrollable (the row overflows 800px); dialog-dismiss asserts
need two pumps (one starts the route pop, one finishes it); tests seed
SharedPreferences.setMockInitialValues({}) since the mock store is
process-global.
Selection model overhaul (session 1 of batch 2): the controller's
selection is an ordered slot list (`_selected`, last = primary;
`selectedAnnotationSlots` / `hasAnnotationSelection` /
`isAnnotationSelected` / `annotationAt(page, slot)`); pages are cached
per revision (`_page()` / `_pageCache`, cleared in
`_invalidateElements`) because `PdfDocument.page()` re-walks the tree
and re-parses /Annots on every call and selection hit tests run per
pointer event. `selectAnnotationAt(toggle:)` is shift/⌘/ctrl-click
(toggle miss leaves the selection alone), `selectAnnotationsIn` is the
marquee (rect-intersect), `selectAllAnnotationsOn` is ⌘A;
`moveSelected`/`deleteSelected` act on the whole selection in one
apply (single undo); resize/rotate/text-edit/restyle gates demand
exactly one selected; `deleteAnnotation` remaps surviving same-page
slots past the removed index (slot−1) so the selection follows the
annotation. Overlay: `_selectMode` = select tool armed OR a tool-null
selection — the viewer mounts the overlay for `hasAnnotationSelection`
too, which is how default-mode mouse selection gets move/resize/
marquee; empty-area drags marquee for mouse-like kinds
(DragStartDetails.kind, null treated as mouse) and pan the viewer for
touch via `onPanViewport` (viewer `_grabPanBy` = negated
`_scrollbarScrollBy`/`_scrollbarPanBy`, list-space deltas); dragging
an unselected annotation selects it and moves it in the same gesture;
the ghost rides only single selections (multi moves as chrome boxes —
painter `extraSelectionRects` + `marqueeRect`). Viewer: a default-mode
mouse tap selects annotations (`_lastPointerKind` from the raw
pointer-down — tap details carry no device kind; touch taps stay
reader gestures), mouse drags from empty/textless space grab-pan
(`_grabPanning` in the selection pan handlers, grab/grabbing cursors;
hover shows `click` over selectable annotations and links, `text`
over text), ⌘A/Ctrl+A → `_onSelectAll` (all annotations on the
current page when the select tool or a selection is live, else the
page's whole text). Test gotchas (editing_multiselect_test.dart,
pdf_viewer_test.dart): MouseRegion.onHover doesn't fire for
addPointer — moveTo somewhere first or the cursor assert reads the
initial value; tapAt(kind: PointerDeviceKind.mouse) resolves without
the 350ms double-tap wait (that recognizer is touch/stylus-only); the
hover-test "empty area" points must sit inside the 800×600 viewport.
Annotation interaction polish (session 2 of batch 2): four features.
(1) Rotated selection chrome: `PdfAnnotation.appearanceQuad`
(annotation.dart) — BBox corners through the form /Matrix then the
§12.5.5 fit onto /Rect, page space, BBox order (ll lr ur ul); equals
the rect corners for unrotated appearances. The overlay derives
`_selectionChrome` = (base rect from quad edge lengths about the quad
center, resting angle = view direction of the ll→lr edge,
canvas.rotate convention) and the painter's `rotation` is now
resting + drag delta (the ghost gets `ghostRotation` = delta only —
its appearance already carries the resting rotation; `ghostTo` split
from `selectionRect` for the same reason). Rotate-drag snap is on the
TOTAL angle (`_rotateResting` captured at drag start), so rotated
annotations snap back to square; the knob hit-test rotates its
position (`_rotatePoint`). Resize handles are suppressed when resting
≠ 0 (a /Rect resize would shear rotated artwork).
(2) Post-edit flash fix: `PdfPageView.onRasterReady` fires when a
full-page raster for the current page object lands; `_PdfViewerPage`
(now stateful) tracks `_rastered` (false from every page-identity
swap) and hands the overlay `rasterCurrent`. On commit the overlay
captures an afterimage — `_commitWithGhost` (move/resize/rotate: takes
ownership of the ghost picture, paints it at the committed rect via
paintAnnotationDragPreview at opacity 1), `_afterShape` (rect/ellipse
drag preview), `_afterText` (a Positioned Text mirroring the inline
editor, pageColor-washed for existing-text edits), `_afterSignature`,
and controller-side `committedInkOn(page)` (finishInk runs on a timer,
so the controller keeps the strokes + the committing revision) — and
keeps painting it until rasterCurrent goes true or the document moves
past `_afterDocument`. Painter: `extraInk` (List of stroke sets with
own color/width — committed ink + signature previews), `afterGhost`,
`afterShape`; `_paintInk` is the factored stroke painter.
(3) Ink auto-commit: `inkCommitDelay` (default 800ms, null = manual)
— addInkStroke (re)arms a Timer firing finishInk; `beginInkStroke()`
(called from the overlay's ink pan-start) holds it mid-stroke so slow
drawings don't split. Toolbar check/discard buttons only show in
manual mode (`inkAutoCommits`). finishInk/discardInk/dispose cancel.
(4) Signature preview: `signaturePlacement(page, x, y)` exposes
placeSignature's layout (page-space strokes, pressures, color, width);
the overlay previews it at 0.55 alpha riding hover (mouse) or a
press-drag (`_signatureDrag`, release places at the last position —
taps still place as before). Test gotchas (editing_polish_test.dart):
don't pixel-sample a selection edge midpoint (the white resize handle
sits there); after undo the OLD raster legitimately still shows the
undone edit (PdfPageView keeps the previous image until re-render) so
assert the afterimage source (committedInkOn == null), not pixels; any
touch gesture on the viewer leaves the double-tap recognizer's 40ms
timer — end such tests with pump(400ms); an Ink annotation's rect hugs
the strokes (pen-width padded), not the placement box.
Sidebar round (session 4 of batch 2): four features. (1) Thumbnail
performance: `controller.apply` takes `pages:` (the page indices an
edit changes visually; null = unknown = all) — every internal call
site names its pages, structural ops (movePage/removePage/flatten)
and host edits leave null. `pageRenderStamp(page)` =
`_renderStampEpoch + _renderStamps[page]` (per-revision page sets in
`_revisionPages`, bumped on apply/undo/redo of exactly the touched
pages). `pageAt(index)` is the public per-revision page cache (use it
anywhere UI reads pages per frame — sidebars now do). The strip
rasterizes tiles via `PdfPageRenderer.renderImage` into a per-sidebar
LRU (`_ThumbnailCache`, 96 entries, hands out `ui.Image.clone()`s so
eviction can't pull pixels from a painting tile; key =
page|stamp|color|pxWidth with 64px width buckets), renders serialized
through a future chain on the cache (one page at a time, PER PANEL —
a static chain strands continuations in a dead async zone once an
earlier zone, e.g. a previous widget test's FakeAsync, completed the
tail; every task try/catches everything so one failing page can't
poison the chain), and only per-tile ListenableBuilders watch
viewer/viewport changes — the outer list rebuilds on controller
notifies alone. Stamps restart at 0 per controller, so a session swap
(opening another document) must drop cached state: the sidebar clears
the cache and each tile resets its imageKey in didUpdateWidget on
controller identity change — without that the new document shows the
old one's thumbnails (keys collide).
`PdfThumbnailSidebar.debugRasterizations` counts real renders for
tests. (2) Resizable panels: both sidebars take `side` (which side of
the viewer they're docked on, `PdfSidebarSide` in editing_panel.dart),
`resizable`, `minWidth`/`maxWidth`; `PdfSidebarResizeGrip` (8px hit
strip, hairline that thickens on hover/drag) reports deltas already
signed toward growth; widths persist as preferences
`thumbnailSidebarWidth`/`annotationSidebarWidth` (null until first
dragged — the widget's `width` param is just the default). Grip keys:
'pdf-thumbnail-resize-grip'/'pdf-annotation-resize-grip'. (3) Follow
the viewer: the strip keeps per-slot GlobalKeys; on currentPage change
it `Scrollable.ensureVisible`s a built tile (keepVisibleAtEnd then
keepVisibleAtStart = minimal scroll), or jumps to an estimated offset
(aspect math mirroring tile layout: 12px side pad, 1px border, 4px
vert pad, 28px footer) and fine-tunes post-frame once built.
(4) Zoom-to flash: `controller.flashAnnotation(page, slot)` →
`pendingFlash` (`(page, slot, sequence)`; dies with any revision via
document-identity check); the sidebar tap calls it after
showRect+select; the overlay (now SingleTickerProviderStateMixin)
runs a 1100ms pulse — amber (0xFFFFB300) ring closing onto the rect
while fading — and calls `expireFlash(sequence)` on completion
(cancels the 1600ms `flashLifetime` backstop Timer, which only
matters when no overlay ever runs the pulse); the viewer mounts the
overlay for `pendingFlash != null` too (links/widgets flash without a
selection). Test gotchas (editing_panels_test.dart): thumbnails are
RawImages now (page_color's wait condition polls RawImage, not
CustomPaint); resize-grip drags eat pointer slop even for mouse kind —
assert greaterThan + prefs equals rendered width, not exact pixels;
tile-tap tests must pump the pulse out (pumpAndSettle, or pump ~2s) or
the backstop timer trips `!timersPending` — that invariant check runs
BEFORE addTearDown(dispose); never `await viewer.jumpToPage` in a
widget test (fake-async deadlock — fire it unawaited and pump); a
queue yield via Future.delayed(zero) leaves stray fake timers, so the
thumbnail render queue serializes on the rasterize awaits alone; never
chain async work through a STATIC Future in widget-tested code — each
test's FakeAsync zone dies with the test and the chain dies with it.
Viewport indicator contrast (Ben: "I still don't see the viewport
preview"): the strip's viewport mark painted in colorScheme.primary —
in a dark M3 theme that's light lavender over the (white) thumbnail,
~1.7:1, invisible; the feature predates dark mode and was only ever
seen against light-theme primary. The mark paints over the PAPER, not
the app surface, so _PageTile now picks whichever of primary/
inversePrimary has the higher WCAG contrast against pageColor (works
for recolored paper too). Contrast tests live in
editing_panels_test.dart (read the private painter's color via a
dynamic cast; light and dark asserted in separate tests per the
AnimatedTheme gotcha).
Viewer-state clobber (the REAL cause of Ben's invisible indicator —
contrast was secondary): PdfViewerController delegates through a
`_state` pointer set in the viewer's initState and cleared in dispose.
When a host recreates the viewer ELEMENT — the example's keyless Row
gained panels on BOTH sides when the async preference load completed,
so updateChildren mismatches at both ends and re-inflates the keyless
middle — the new state attaches in initState, then the OLD state's
deferred dispose (tree finalization) nulled `_state` again. Every
controller round-trip (visiblePageRegion, jumpToPage, showRect,
search) silently no-ops from then on; values the state PUSHES into
the controller (currentPage, pageCount) keep working, which masks it.
Fix: dispose only detaches `if (identical(_controller._state, this))`;
the example also keys the Row children (panel toggles now preserve the
viewer element and the reading position). Regression test: "controller
survives the host recreating the viewer element" (pdf_viewer_test).
Widget tests can't catch this class of bug when they mount the final
layout in one pump — the live-app tells were tile taps not navigating
and dragging the viewer's scrollbar (cliclick + screencapture against
the running macOS app made it falsifiable). Related cosmetic fix found
the same way: _PageTile's border was DecoratedBox, whose child is NOT
inset, so the full-bleed RawImage covered the 1-2px ring (current-page
outline included) — it's a Container now (decoration padding insets
the child; the strip's width math already assumed width-26).
Theming round (session 5 of batch 2): `PdfViewerTheme`/
`PdfViewerThemeData` (theme.dart, exported) — an InheritedWidget; every
field nullable, null = stock look, widget params (backgroundColor) win
over the theme. Fields: canvasColor, selectionColor, searchMatchColor,
currentSearchMatchColor, annotationChromeColor (selection boxes/
handles/marquee + the inline text editor's border), elementChromeColor,
flashColor, and scrollbar (`PdfScrollbarThemeData`: thumb/thumbActive/
outline/track/trackActive). _HighlightPainter and
_EditingPreviewPainter take `theme` (chrome statics became getters with
fallbacks; translucent fills derive via withAlpha(0x1A)/(0x14) so a
custom chrome recolors them too) — both compare it in shouldRepaint.
The viewer's `_PdfScrollbar` moved to scrollbar.dart as a public
`PdfScrollbar`: transform now optional (plain mode = scale 1, offset =
scroll.pixels), onScrollBy optional (null drives the ScrollController
directly, clamped), `thumbKey` for tests. Both sidebars suppress the
implicit desktop bar (ScrollConfiguration scrollbars:false) and mount
it over their lists — thumb keys 'pdf-thumbnail-scrollbar-thumb' /
'pdf-annotation-scrollbar-thumb', inset by PdfSidebarResizeGrip.width
when the grip rides the same right edge. The annotation list gained a
ScrollController, which surfaced a crash class: toggling multi-select
used to swap `list` ↔ `Column(header, Expanded(list))`, re-inflating
the ListView — old + new positions both attached for a frame and
`controller.position` asserts. Fix shape is the session-4 lesson again:
one tree shape always (Column with the header conditional and the
Expanded keyed) AND the scrollbar treats `positions.length != 1` as
"no metrics" instead of touching `.position`. Tests:
pdf_theme_test.dart (theme plumbing via dynamic painter casts, thumb
decoration colors, sidebar bar presence/drag — mouse-kind
startGesture+moveBy, since tester.drag eats slop).
Color formats (session 6 of batch 2): `PdfColorFormat` {hex, rgb, hsl,
cmyk} (carries its display `label`), exported from
editing_color_picker.dart. The picker's value row switches via a
compact PopupMenuButton (key 'pdf-color-format'); hex stays the
default and its field is unchanged — the legacy picker test finds
exactly one TextField and taps 260-wide-layout offsets, so neither
the default nor the picker width may change. Channel modes show dense
centered fields (keys 'pdf-color-channel-N', labels below, maxLength
from the channel max, ZERO horizontal contentPadding — four CMYK
fields share ~130px and a centered '100' clips with any side padding;
found in the real app, not in tests). One model (`_hsv`): SV/hue
drags and format switches rewrite the visible fields (`_syncFields`);
a channel edit parses the entire visible row (the other fields
already hold their values) and never rewrites it, so typing isn't
clobbered — unparsable/emptied input no-ops, values clamp to
[0, max]. HSL via HSLColor; CMYK is the naive device conversion
(k = 1−max(r,g,b), no color management — entry/display only, stated
in the dartdoc). Format persistence: the picker is preferences-free
(`initialFormat` + `onFormatChanged` params on it and
showPdfColorPicker); `PdfEditingPreferences.colorPickerFormat` (key
`colorPickerFormat`, stored by name) is wired by the toolbar's 'More
colors…' and the example's page-color button — preferences imports
the enum from the picker, never the reverse. Tests: editing_test.dart
(per-format round-trips incl. CMYK 100/0/0/0→cyan, drag rewrites the
fields, empty-field no-op) and the preferences round-trip; verified
live on macOS incl. format persistence across an app restart.
Session 7 (saving + showcase): macOS saving was ALREADY fixed —
a913df0 flipped user-selected.read-only → read-write in both
entitlement profiles; this session verified the whole flow live
(save panel → /tmp write, Replace-overwrite, toast, output parses).
The demo (example/lib/demo_document.dart) is now a 6-page feature
showcase: pages 1-2 unchanged (demo_test.dart taps page-1 buttons at
fixed PDF coords and the GoTo lands on page 2 — don't move them);
page 1 gained a TOC of /Fit GoTo links (placeholders @PGn@ patched
after object numbering). Page 3 graphics (dash/join rows, even-odd
star, Bézier heart, /ShAx stitched type-3-function axial + /ShRad
radial via `sh`, Multiply circles, ca alpha row, CMYK `k` + gray `g`
swatches), page 4 typography (7 standard fonts, Tr 0/1/2 — Tr 7 text
clip is NOT implemented, don't demo it; Tc/Tw/Tz/Ts each reset inline
since text state persists across BT/ET), page 5 images (hue-wheel RGB
XObject as ASCIIHex, color-key /Mask over stripes, 1-bit /ImageMask
smiley ×2, 4×4 inline image), page 6 annotations & forms: the base
file hand-writes field skeletons (text/checkbox with /MK but no /AP —
appearances generate on fill; radio kids NEED hand-written /AP /N
state forms or onStates is empty and setRadioValue throws; combo
needs /Opt + comboFlag 131072) plus /AcroForm /DR /Helv, then
_authorShowcase reopens the bytes and authors 10 annotations + fills
all 4 fields through PdfEditor — the demo is a build-time smoke test
of the authoring pipeline (asserted in demo_document_test.dart).
Inline-image bug found by the showcase: BI..ID..EI synthesizes a
fresh CosStream every interpretation pass, but renderPicture decodes
in a collector pass and paints in a second pass — the identity-keyed
image map never hit, so inline images NEVER rendered. Fix:
PdfImageRequest.isInline (set by _drawInlineImage), pdfImageKey()
in image_decoder.dart returns a value key (PdfInlineImageKey: dict
toString + data bytes) for inline requests, stream identity for
XObjects (the xref cache makes those stable); ImageCollector now
collects requests, decodeImages takes requests and keys by
pdfImageKey, CanvasPdfDevice.images is Map<Object, ui.Image>.
Regression test: pdf_flutter/test/inline_image_test.dart. Two Ghent
baselines moved because GWG090's Type 3 bitmap-font row (CharProcs
painting inline images) now renders — re-baselined as an improvement.
