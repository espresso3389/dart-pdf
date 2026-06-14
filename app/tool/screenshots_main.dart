// Self-driving build of the DartPDF app, used only to capture device
// screenshots of the real app screens (welcome, editor with the tab
// strip, light + dark). It steps through a fixed list of states, holding
// each one still and printing a marker line the host capture tool
// watches for:
//
//   @@SHOT@@ <name>     a scene is settled and on screen — grab it now
//   @@SHOT_DONE@@       all scenes done — the host can quit `flutter run`
//
// tool/screenshots.sh (in this package's sibling example, shared) drives
// it; or run by hand once a device is booted:
//
//   fvm flutter run -d <device> -t tool/screenshots_main.dart
//
// This entry lives under tool/ (not lib/) so it may import the example
// package as a dev dependency for its feature-showcase document.

import 'dart:async';

import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:pdf_viewer_example/demo_document.dart';

import 'package:dart_pdf_editor_app/editor_screen.dart';

/// Milliseconds each scene is held on screen after its marker, giving the
/// host time to capture. Overridable: `--dart-define=SHOT_HOLD_MS=4000`.
const _holdMs = int.fromEnvironment('SHOT_HOLD_MS', defaultValue: 2600);

void main() => runApp(const AppScreenshots());

class AppScreenshots extends StatefulWidget {
  const AppScreenshots({super.key});

  @override
  State<AppScreenshots> createState() => _AppScreenshotsState();
}

/// Which screen a scene shows.
enum _Screen { welcome, editor }

class _Scene {
  const _Scene(this.name,
      {required this.screen, this.themeMode = ThemeMode.light});
  final String name;
  final _Screen screen;
  final ThemeMode themeMode;
}

const _scenes = <_Scene>[
  // The real landing screen with no document open.
  _Scene('01-welcome', screen: _Screen.welcome),
  // The editor with the showcase document and the browser-style tab strip.
  _Scene('02-editor', screen: _Screen.editor),
  // The same editor in dark mode.
  _Scene('03-dark', screen: _Screen.editor, themeMode: ThemeMode.dark),
];

class _AppScreenshotsState extends State<AppScreenshots> {
  final _prefs = PdfEditingPreferences();
  late final _doc = (bytes: buildDemoPdf(), title: 'Feature showcase');

  _Scene _scene = _scenes.first;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _prefs.dispose();
    super.dispose();
  }

  Future<void> _settle({bool heavy = false}) async {
    for (var i = 0; i < 3; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    await Future<void>.delayed(
        Duration(milliseconds: heavy ? 2400 : 1300));
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    for (final scene in _scenes) {
      _prefs.themeMode = scene.themeMode;
      if (mounted) setState(() => _scene = scene);
      await _settle(heavy: scene.screen == _Screen.editor);
      debugPrint('@@SHOT@@ ${scene.name}');
      await Future<void>.delayed(Duration(milliseconds: _holdMs));
    }
    debugPrint('@@SHOT_DONE@@');
  }

  @override
  Widget build(BuildContext context) {
    // A fresh editor per screen kind (keyed) so the welcome→editor switch
    // re-runs initState and the document opens; the light→dark step keeps
    // the same editor key so the open document survives the theme flip.
    final editorKey = ValueKey(_scene.screen);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DartPDF',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: _prefs.themeMode,
      home: EditorScreen(
        key: editorKey,
        prefs: _prefs,
        initialDocument: _scene.screen == _Screen.editor ? _doc : null,
      ),
    );
  }
}
