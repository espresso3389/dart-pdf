# Background-isolate page rendering — implementation brief

**Status:** proposed, not started.
**Goal:** move PDF page interpretation off the UI thread so scrolling never
freezes, even on heavy (CAD) documents.
**Audience:** the engineer/agent who picks this up. Read this whole doc before
touching code; the hard parts (images, text, soft masks, web) are at the end and
they shape the design.

---

## 1. Why

Every page is interpreted **synchronously on the UI (root) isolate** inside
`PdfPageRenderer.renderPicture`. On a 40 MB / 133-page A3 CAD file
(`MW307(TNT975)F-UPS-ZB.pdf`, Ben's repro), measured cost per page:

| stage | cost (page 109, 10.7 MB content stream, 644k ops) |
|---|---|
| filter decode (`contentBytes`) | ~20 ms |
| `ContentStreamParser.parse` | ~300 ms (was 416 ms before the June parser rewrite) |
| image-collect (scan-only) pass | ~100 ms |
| paint pass | ~90 ms (null device; more with the real canvas) |

So `renderPicture` blocks the UI thread for **~300–500 ms on typical heavy
pages and ~1 s on the worst**. Whole-doc interpret total is ~6 s.

The existing fast-scroll machinery (render hold, velocity tracking, preview
cache, `PdfPageRenderScheduler`) *hides* this during a fling, but you still pay
the full synchronous walk:
- on **scroll-settle** (the visible heavy page interprets → freeze), and
- in the background **`_prerenderPreviews`** loop (full-interprets all 133 pages,
  one per frame, after open → seconds of stutter when idle).

No amount of pacing fixes a single frame that is itself 500 ms long. The only
real fix is to not run the interpret on the UI thread.

**Constraint that makes this non-trivial:** `ui.Picture` / `ui.Canvas` /
`ui.Image` cannot cross isolate boundaries. We cannot just "run renderPicture in
an isolate." We must split it.

---

## 2. The shape of the fix

Split `renderPicture` into a **heavy, portable** half and a **cheap, dart:ui**
half:

```
BACKGROUND ISOLATE (pure Dart, no dart:ui)          MAIN ISOLATE (dart:ui)
─────────────────────────────────────────          ──────────────────────
open PdfDocument from bytes
parse content stream  ← the 300 ms
scan-only image collect pass
decode images → raw RGBA (the heavy codec work)
paint pass into a RecordingPdfDevice
  → a flat, serializable COMMAND BUFFER
            │
            │  TransferableTypedData (zero-copy)
            ▼
                                                    replay command buffer
                                                    into a Canvas via the
                                                    existing CanvasPdfDevice
                                                    RGBA → ui.Image (cheap)
                                                    → ui.Picture
```

The ~490 ms of parse + interpret + image decode moves off the UI thread. What
stays on the UI thread is the **replay** (walk a pre-built command list, no
parse, no interpret, no resource resolution) plus turning already-decoded RGBA
buffers into `ui.Image`s — both cheap, target < 16 ms even on the monster page.

### Why a command buffer and not "just send the picture"
`PdfDevice` (`packages/pdf_graphics/lib/src/device.dart`) is the interpreter's
output interface — 13 callbacks (`fillPath`, `strokePath`, `clipPath`,
`drawText`, `drawImage`, `save`/`restore`, `beginGroup`/`endGroup`,
`beginSoftMasked`/`endSoftMasked`, `fillPathGradient`, `fillMesh`,
`setBlendMode`). Its arguments are **already almost entirely pure-Dart value
types** that live in `pdf_graphics` (VM + web, no dart:ui):

- `PdfPath` = `List<PdfPathSegment>` (sealed: MoveTo/LineTo/CurveTo, plain
  doubles — `packages/pdf_graphics/lib/src/path.dart`)
- `PdfColor`, `PdfMatrix`, `PdfStroke`, `PdfFillRule`, `PdfGradient`, `PdfMesh`,
  `PdfBlendMode`, `PdfRect`
- `PdfTextRun` (text string, transform, color, width, fontName, fontSize, flags)
  with `glyphs: List<PdfGlyphPlacement>` whose outlines are `PdfPath`s.

So **the recording device records the callbacks essentially verbatim** into a
serializable list, and the replay device feeds them straight back into the
*unchanged* `CanvasPdfDevice`. The interpreter, the device interface, and the
canvas device do not need to change. We only add a recorder, a serializer, an
isolate entrypoint, and a replay walk.

The only callback args that aren't trivially serializable are the **image
pixels** and the **`drawMask` closure** in `endSoftMasked` — both handled below.

---

## 3. Concrete design

### 3a. `RecordingPdfDevice` — new, in `pdf_graphics` (pure Dart)
`packages/pdf_graphics/lib/src/recording_device.dart`

Implements `PdfDevice`. Each call appends a record to a growable command list.
Two viable encodings — **pick the typed-binary one** for the geometry-heavy
common case, it's the difference between this being a win and a wash:

- **Option A (start here, simplest):** a `List<Object>` of small record objects
  (`_FillPathCmd(path, color, rule, alpha)`, …). Serialize with a hand-written
  writer into a `ByteData`/`Uint8List` (see 3c). Easy to get correct.
- **Option B (optimize later if needed):** stream geometry directly into growed
  typed arrays (a `Float32List` for path coords, a `Uint8List` for opcodes/colors)
  as calls arrive, so there's no intermediate object allocation. 644k ops on the
  monster page means object churn matters; profile Option A first.

Nesting: `beginGroup`/`endGroup`, `beginSoftMasked`/`endSoftMasked`, and
`save`/`restore` are just opcodes in sequence — the tree structure is implicit
in the open/close pairing, exactly as the canvas device already tracks it
(`_knockout` stack, save/restore). **`endSoftMasked` is the one with a closure:**
its `drawMask` callback paints the mask group's content *through the same
device*. The interpreter invokes it synchronously during `endSoftMasked`. So the
recorder records a `BEGIN_SOFTMASK_CONTENT` opcode, lets the closure run (its
nested device calls append in order), then a `END_SOFTMASK` opcode carrying the
scalar args (`luminosity`, `backdrop`, `backdropLuminance`, `transferScale`,
`transferOffset`). On replay, the main-isolate walk reconstructs the closure:
`endSoftMasked(..., drawMask: () => replay(commandsBetweenMarkers))`.

### 3b. Image handling (the main risk — read carefully)
Image pixels can't be a `ui.Image` in the isolate. Strategy:

1. Refactor `decodeImages` / `_decodeOne`
   (`packages/dart_pdf_editor/lib/src/image_decoder.dart`) to expose a
   **decode-to-RGBA** step that returns `(Uint8List rgba, int w, int h, bool
   premultiplied)` instead of a `ui.Image`. The pixel path already exists
   internally — `_imageFromPixels` (line ~577) calls `ui.decodeImageFromPixels`
   on RGBA that the codecs already produced. We're splitting *before* that call.
2. **Where does decode-to-RGBA run?** Most codecs are pure Dart and isolate-safe:
   the `image` package (`img.JpegData`, used at image_decoder.dart:371), and the
   `pdf_document` codecs (PNG `PngImage`, CCITT, JBIG2, JPX). **One path is not
   isolate-safe:** `_decodeOne` decodes DCTDecode via `ui.instantiateImageCodec`
   (line ~278). In the isolate, route DCT through the pure-Dart `img.JpegData`
   path instead (already present). Verify pixel-equivalence (see §6) — there may
   be a documented ±1 / chroma-subsampling difference vs the platform JPEG codec;
   if it's visible, fall back to shipping the raw JPEG bytes to the main isolate
   for that one image and decoding there.
3. The command buffer references images by an **index into an image table**
   transferred alongside it. Each table entry = RGBA bytes + dims + premultiply
   flag (as `TransferableTypedData`). On the main isolate, `_imageFromPixels`
   turns each into a `ui.Image` (cheap), and the replay's `drawImage` looks them
   up by index. Keep the existing `PdfImageCache` on the main isolate keyed by
   `pdfImageKey` so repeat renders / thumbnails / previews still share one
   `ui.Image` — the isolate only re-decodes images the main cache doesn't have
   (pass the set of cached keys into the isolate request so it can skip them and
   the main side decodes those from its cache; or simpler v1: always decode in
   the isolate, dedupe on the main side by key before `_imageFromPixels`).

### 3c. Serialization
Pure data → bytes. Use a compact manual format (not `jsonEncode` — too slow/big
for 644k ops). A `ByteData` writer with:
- a `Float64List` (or `Float32List` if precision allows — **check**: PDF coords
  can be large; `Float32` is probably fine for on-screen raster but verify
  against the render baselines) for all path/transform coordinates,
- a `Uint8List` for opcodes + enum tags + colors (ARGB as 4 bytes),
- a side list of strings (text, font names) and the image table.

Wrap each buffer in `TransferableTypedData.fromList([buffer])` for zero-copy
hand-off. Decode on the main isolate with a mirror reader.

### 3d. Isolate entrypoint + pool
`packages/dart_pdf_editor/lib/src/render_isolate.dart`

- Request: `{ Uint8List docBytes (or a shared TransferableTypedData), int
  pageIndex, Color pageColor, bool annotations, skipAnnotation spec, Set<Object>
  imageKeysAlreadyCached, String? password }`. Note: the isolate **re-opens its
  own `PdfDocument`** from the bytes (`PdfDocument.open(bytes, password: …)`),
  gets `.cos`, builds the interpreter exactly like renderPicture does. Encrypted
  docs need the password threaded through.
- Response: command buffer + image table (TransferableTypedData) + page size +
  rotation (so the main side sets up the same canvas transform as
  renderPicture:78-92).
- Use a **persistent isolate pool** (size ≈ `Platform.numberOfProcessors - 1`,
  cap ~3–4), not `Isolate.run` per page — re-opening a 40 MB `PdfDocument` per
  page is wasteful. Better: a long-lived worker per isolate that keeps the
  opened `PdfDocument` for the *current* document and answers page requests by
  index; on document swap, send new bytes once. This makes the parse the only
  per-page cost. (`flutter_isolate`/`worker_manager` exist but prefer a small
  hand-rolled `ReceivePort`/`SendPort` pool — fewer deps, the team avoids
  `dart:io` and heavy packages.)
- Send the doc bytes **once per document** via `TransferableTypedData` and have
  workers cache the opened document, keyed by a document id.

### 3e. Replay on the main isolate
`packages/dart_pdf_editor/lib/src/render_replay.dart`

A function `Future<ui.Picture> replayToPicture(buffer, imageTable, page size,
rotation, pageColor)` that:
1. turns each image-table entry into a `ui.Image` (dedupe against
   `PdfImageCache`),
2. sets up the recorder/canvas with the **same** background-fill + rotation +
   y-flip transform block as `renderPicture` (renderer.dart:58-92),
3. walks the command buffer, calling the **existing** `CanvasPdfDevice` methods
   (reconstructing the `drawMask` closure for soft masks),
4. `recorder.endRecording()`.

This is the only new code that touches dart:ui besides image creation, and it
must be byte-for-byte equivalent in its canvas calls to today's paint pass.

---

## 4. Integration points

- **`PdfPageRenderer.renderPicture`** (`renderer.dart:35`) gains an async
  isolate-backed sibling, e.g. `renderPictureAsync` that does
  isolate-interpret → replay. Keep the synchronous `renderPicture` as the
  fallback (web, and tests). A top-level flag / capability check decides which.
- **`PdfPageRenderScheduler`** (`render_scheduler.dart`) currently paces *one
  synchronous interpret per frame*. With isolate rendering, it should instead
  *dispatch up to N concurrent isolate requests* (pool-sized) and apply pictures
  as they return. The "holding" flag still gates dispatch during fast flings.
  This is a real change to the scheduler's contract — design it so the
  synchronous path still works when isolates are unavailable.
- **`PdfPageView._renderNow`** (`pdf_page_view.dart:294`) already awaits an async
  `renderPicture`; it mostly cares that a `ui.Picture` eventually arrives. The
  preview cache `putFromPicture` and detail-patch `rasterizeRegion` paths are
  unchanged (they consume the finished picture/raster).
- **`_prerenderPreviews`** (`pdf_viewer.dart:895`) becomes far cheaper to run
  because each preview is now an isolate job, not a UI-thread freeze — but keep
  the "bail while scrolling" logic so we don't saturate the pool mid-fling.

---

## 5. Web

Web has no shared-memory isolates and **cannot run dart:ui codecs or this
interpret in a worker the same way.** `Isolate.run` is unsupported on web;
`compute` spins a web worker but can't share the document or return dart:ui
objects. **Plan: native (iOS/Android/macOS/Windows/Linux) gets the isolate path;
web keeps the current synchronous `renderPicture`.** Gate with
`kIsWeb`. The whole feature must degrade cleanly to today's behavior — the
synchronous path stays the reference implementation and the test oracle.

---

## 6. Testing (this is how you know it's correct)

The bar: **the replay path must produce pixel-identical pictures to today's
synchronous paint pass.** Two layers, both already exist in this repo — use them
as the oracle:

1. **Picture/command equivalence (pure-ish):** a new test that, for a set of
   pages (Ghent composites + a few PDF.js edge cases + a CAD page), runs the
   *recording device* and the *replay* and asserts the resulting `ui.Picture`
   rasterizes identically to `renderPicture`'s output (reuse the diff harness
   from `ghent_render_test.dart`: fail when >0.05% of pixels differ by >8/chan).
2. **Existing render baselines** (`dart_pdf_editor/test/ghent_render_test.dart`,
   `pdfjs_render_test.dart`): run the isolate path through them. They must not
   move. (Note: ~14 Ghent render baselines fail pre-existing on Ben's machine —
   confirm your starting baseline by stashing first, per CLAUDE.md.)
3. **Soft masks / transparency groups / mesh shadings / inline images** are the
   serialization-fragile callbacks — make sure the chosen test pages exercise
   each (Ghent has overprint/softmask/blend-mode/DeviceN pages; the demo doc
   page 3 has `sh` shadings and `Multiply`; page 5 has inline + stencil images).
4. **Image codecs:** add a KAT-style check that isolate decode-to-RGBA matches
   the main-isolate decode for PNG/JPEG/CCITT/JBIG2/JPX (the codecs already have
   KATs in `pdf_document`; the new risk is only the DCT-via-img path).

Perf gate: re-run the per-page walk timing. Tooling is gone now but trivial to
recreate — a `NullDevice implements PdfDevice` and
`PdfInterpreter(cos: doc.cos, device: …).drawPage(doc.page(i))` in a loop with a
`Stopwatch` (see the old `tool/interp_timing.dart`, which still exists and times
one walk per page). Success = the UI thread frame time during a settle on the
CAD doc drops from ~300–500 ms to < 16 ms.

---

## 7. Suggested milestones (land incrementally, keep green)

1. **Recorder + replay, same isolate.** Add `RecordingPdfDevice` and
   `replayToPicture`; wire a `renderPicture` variant that records then replays,
   *no isolate yet*. Prove pixel-identity against the baselines. This de-risks
   serialization completely before any isolate complexity.
2. **Image decode-to-RGBA split.** Refactor `_decodeOne` to a pixel-returning
   form; build the image table; replay creates `ui.Image`s. Still single-isolate.
3. **One background isolate.** Move the record half into a worker; transfer the
   buffer; replay on main. Prove identity + measure the UI-thread win.
4. **Isolate pool + per-document caching** (open once, render by index).
5. **Scheduler rework** to dispatch concurrently; `_prerenderPreviews` reuse.
6. **Web fallback gate** + final baseline sweep.

Each milestone is independently testable against the render baselines.

---

## 8. Gotchas / notes

- The interpreter pulls resources (fonts, XObjects, ExtGState, shadings) from
  the `CosDocument` via the xref **during** the walk. That's fine — it all
  happens in the isolate where the doc is open. Nothing resource-related crosses
  the boundary; only the flattened command output does.
- `_sharedFonts` (interpreter.dart:191) is a **static** cross-render font cache.
  In a worker isolate it's a *per-isolate* static — each worker warms its own.
  That's acceptable (warms once per worker per font), but be aware repeat renders
  of the same page on *different* workers re-parse the font. Per-document worker
  affinity (route a document's pages to the same worker) mitigates it.
- Text without embedded outlines (`run.hasOutlines == false`) is shaped on the
  main isolate by `CanvasPdfDevice` via `TextPainter` + the `_textCache`
  (canvas_device.dart:31). Good — keep that on the main side; the recorder just
  carries the `PdfTextRun` data. Only embedded-glyph runs carry `PdfPath`
  outlines, which serialize as path data. So **substituted-text shaping stays on
  the UI thread** — measure whether it's now the dominant remaining cost on
  text-heavy pages; if so, a later step can pre-shape in the isolate using the
  font collection, but don't scope that here.
- `PdfMatrix`/`PdfColor`/`PdfPath`/`PdfGradient`/`PdfMesh` are all in
  `pdf_graphics` and dart:ui-free, so `RecordingPdfDevice` and the command model
  belong in `pdf_graphics` (keeps the layering rule: dart:ui only in
  `dart_pdf_editor`). The isolate entrypoint, replay, and image work touch
  dart:ui and stay in `dart_pdf_editor`.
- Encrypted documents: thread the password into the isolate request.
- Don't forget `disposeImages` parity — the replay must dispose the `ui.Image`s
  it creates after `endRecording`, exactly as renderer.dart:102 does, since the
  picture retains its own refs.

---

## 9. Files to create / change (summary)

| file | action |
|---|---|
| `pdf_graphics/lib/src/recording_device.dart` | new — `RecordingPdfDevice` + command model + serializer |
| `pdf_graphics/lib/src/render_command.dart` | new (optional split) — opcode/record definitions |
| `dart_pdf_editor/lib/src/render_replay.dart` | new — `replayToPicture` (dart:ui) |
| `dart_pdf_editor/lib/src/render_isolate.dart` | new — worker pool, request/response, entrypoint |
| `dart_pdf_editor/lib/src/image_decoder.dart` | change — expose decode-to-RGBA; isolate-safe DCT path |
| `dart_pdf_editor/lib/src/renderer.dart` | change — `renderPictureAsync`, keep sync fallback |
| `dart_pdf_editor/lib/src/render_scheduler.dart` | change — concurrent dispatch |
| `dart_pdf_editor/lib/src/pdf_page_view.dart` | minor — route through async render |
| tests | new equivalence test + run isolate path through ghent/pdfjs render tests |

---

## 10. Baseline measurements (June 2026, post parser-rewrite)

Repro file: `MW307(TNT975)F-UPS-ZB.pdf` (133 pages, 40 MB, A3 CAD).
- whole-doc single interpret walk: total ~6.15 s, avg 46 ms, median 36 ms,
  p90 63 ms, max 331 ms (page 121/109).
- worst page `renderPicture` ≈ walk + extra paint/scan pass ≈ ~0.5 s today.
- target after this work: UI-thread cost per page < 16 ms (replay only); the
  interpret happens concurrently in workers.

The content-stream parser was already optimized in the same session that wrote
this doc (`ContentStreamParser.parse` rewritten to drive the lexer directly:
422 → 301 ms on page 109, ~25% off every render path). That change is orthogonal
and already landed; this isolate work is the remaining, larger win.
