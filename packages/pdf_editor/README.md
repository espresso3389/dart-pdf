# pdf_editor

A Flutter PDF viewer and editor rendered natively in Dart, with no
platform views or native PDF libraries. The same code runs on iOS,
Android, macOS, Windows, Linux, and the web.

There is a [live demo](https://dart-pdf-demo.web.app) of the example app
on Flutter web, with a built-in feature showcase document.

Built on the pure-Dart
[dart-pdf suite](https://github.com/ben-milanko/dart-pdf): `pdf_cos`
(file syntax) ← `pdf_document` (document semantics + editing) ←
`pdf_graphics` (interpreter + fonts) ← `pdf_editor` (Flutter widgets).

## Viewing

- Zooming/panning viewer with fit-page and fit-width modes, deep-zoom
  detail rendering past the raster caps, and exact scroll metrics on
  long mixed-size documents.
- Text selection (mouse, and touch with selection handles), full-text
  search with a results panel, link navigation, outlines.
- Theming via `PdfViewerTheme`, dark mode, arbitrary page colors, and a
  hide-all-annotations toggle.

## Editing

Every edit is an incremental save: undo/redo is built in, and revisions
are byte prefixes of one buffer.

- Annotation tools: highlight/underline/strikeout/squiggly, ink with
  stylus pressure and spline smoothing, shapes, free text with in-place
  editing, notes, stamps (including custom saved stamps), and a saved
  ink signature.
- Direct manipulation: select (single, marquee, ⌘A), move, resize, and
  rotate with live appearance previews, plus a slicing circle eraser,
  copy/cut/paste, z-order, restyling, and a context menu with
  host-extensible entries (right-click, or long-press on touch).
- Forms: fill text/checkbox/radio/choice fields in place, set button
  images, and administer fields (add, rename, retype, delete, flatten).
  Fields are highlighted with a translucent wash by default
  (`PdfViewer.highlightFormFields`).
- Panels: thumbnail sidebar with drag-reorder, annotation sidebar with
  search and multi-select, properties panel, and search results panel,
  all resizable and persisted.
- Permissions: `/F` read-only and locked flags are honored, and a
  `canEditAnnotation` predicate implements policies like "users may
  only edit their own annotations" in one line.
- Sync: an `annotationChanges` feed plus `applyRemoteChange` for wiring
  annotations to a collaborative store (Firestore, websockets, etc.).

## Quick start

```dart
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_editor/pdf_editor.dart';

// Read-only viewing
PdfViewer(document: PdfDocument.open(bytes));

// Editing
final editing = PdfEditingController(bytes);

ListenableBuilder(
  listenable: editing,
  builder: (context, _) => Column(children: [
    PdfEditingToolbar(controller: editing),
    Expanded(
      child: PdfViewer(
        document: editing.document, // rebuild with each revision
        editing: editing,
      ),
    ),
  ]),
);

// Saving
final Uint8List saved = editing.bytes;
```

The [example app](example) wires up everything: toolbars, all four
panels, search, page navigation, preferences, and dark mode. It runs on
all six platforms.

## Under the hood

Encrypted files (RC4/AES-128/AES-256, encrypt-on-write), digital
signature validation, the full shading and blend-mode set, ICC color,
CCITT/JBIG2/JPEG 2000 images, and lenient parsing of broken real-world
files, with conformance pinned against the Ghent Output Suite and the
PDF.js test corpus.
