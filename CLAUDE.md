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

## Roadmap context

See README.md. Current frontier: incremental-update writer, then the
content-stream interpreter (device interface modeled on MuPDF/pdf.js so text
extraction and rendering share one interpreter).
