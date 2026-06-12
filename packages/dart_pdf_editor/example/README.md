# pdf_viewer_example

The demo app for `dart_pdf_editor`: a full viewer/editor with search, text
selection, the editing toolbar and sidebars, plus an interactive demo
document whose links and overlays drive the surrounding Flutter app.

Runs on every Flutter platform — macOS, iOS, Android, web, Windows, and
Linux:

```sh
fvm flutter run -d macos     # or: ios / android / chrome / windows / linux
```

Open a file straight away on desktop with
`--dart-define=PDF=/path/to/file.pdf`.

File access matches each platform's conventions: opening always uses the
native picker; saving uses a save dialog on desktop, a browser download
on the web, and the share sheet on iOS and Android.
