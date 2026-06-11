import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'editing_signature.dart';

/// Editing-UI preferences, persisted on the local device.
///
/// Every [PdfEditingController] creates one by default, so tool styles
/// (color, stroke width, opacity, font size) and the stylus mode come
/// back the way the user left them, in this session and the next.
/// Panel visibility ([showThumbnailSidebar], [showAnnotationSidebar])
/// lives here too for the host's chrome — pass one instance to both the
/// controller and the surrounding scaffold:
///
/// ```dart
/// final prefs = PdfEditingPreferences();
/// // later, per document:
/// final editing = PdfEditingController(bytes, preferences: prefs);
/// ```
///
/// Values load asynchronously ([ready]); each change is written back
/// immediately. Where no local storage exists — plain widget tests, for
/// example — loading fails silently and the defaults stand.
class PdfEditingPreferences extends ChangeNotifier {
  PdfEditingPreferences() {
    _ready = _load();
  }

  static const _prefix = 'pdf_flutter.editing.';

  SharedPreferences? _store;
  late final Future<void> _ready;
  bool _modified = false;

  /// Completes once stored values have been applied — or storage turned
  /// out to be unavailable and the defaults stand.
  Future<void> get ready => _ready;

  Color _color = const Color(0xFFE53935);
  double _strokeWidth = 2;
  double _fontSize = 14;
  double _opacity = 1;
  bool _fingerDrawsInk = true;
  bool _showThumbnailSidebar = false;
  bool _showAnnotationSidebar = false;
  PdfInkSignature? _signature;

  Future<void> _load() async {
    final SharedPreferences store;
    try {
      store = await SharedPreferences.getInstance();
    } catch (_) {
      return; // no local storage here (e.g. widget tests) — defaults stand
    }
    // a value set while the disk read was in flight wins over the stored one
    if (!_modified) {
      final color = store.getInt('${_prefix}color');
      if (color != null) _color = Color(color);
      _strokeWidth = store.getDouble('${_prefix}strokeWidth') ?? _strokeWidth;
      _fontSize = store.getDouble('${_prefix}fontSize') ?? _fontSize;
      _opacity = store.getDouble('${_prefix}opacity') ?? _opacity;
      _fingerDrawsInk =
          store.getBool('${_prefix}fingerDrawsInk') ?? _fingerDrawsInk;
      _showThumbnailSidebar =
          store.getBool('${_prefix}showThumbnailSidebar') ??
              _showThumbnailSidebar;
      _showAnnotationSidebar =
          store.getBool('${_prefix}showAnnotationSidebar') ??
              _showAnnotationSidebar;
      final signature = store.getString('${_prefix}signature');
      if (signature != null) _signature = PdfInkSignature.decode(signature);
    }
    _store = store;
    notifyListeners();
  }

  void _write(Future<Object?> Function(SharedPreferences store) write) {
    _modified = true;
    final store = _store;
    if (store != null) unawaited(write(store));
  }

  /// The color new annotations are created with.
  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    _write((s) => s.setInt('${_prefix}color', value.toARGB32()));
    notifyListeners();
  }

  /// Stroke width for ink and shape annotations, in PDF points.
  double get strokeWidth => _strokeWidth;

  set strokeWidth(double value) {
    if (value == _strokeWidth) return;
    _strokeWidth = value;
    _write((s) => s.setDouble('${_prefix}strokeWidth', value));
    notifyListeners();
  }

  /// Font size for free-text annotations, in PDF points.
  double get fontSize => _fontSize;

  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    _write((s) => s.setDouble('${_prefix}fontSize', value));
    notifyListeners();
  }

  /// Opacity (0–1] new ink, shape, markup, and stamp annotations are
  /// created with.
  double get opacity => _opacity;

  set opacity(double value) {
    if (value == _opacity) return;
    _opacity = value;
    _write((s) => s.setDouble('${_prefix}opacity', value));
    notifyListeners();
  }

  /// Whether touch pointers draw with the ink tool (see
  /// [PdfEditingController.fingerDrawsInk]). Persisted so a stylus
  /// user's palm rejection survives reopening the app.
  bool get fingerDrawsInk => _fingerDrawsInk;

  set fingerDrawsInk(bool value) {
    if (value == _fingerDrawsInk) return;
    _fingerDrawsInk = value;
    _write((s) => s.setBool('${_prefix}fingerDrawsInk', value));
    notifyListeners();
  }

  /// Whether the host shows the page thumbnail sidebar.
  bool get showThumbnailSidebar => _showThumbnailSidebar;

  set showThumbnailSidebar(bool value) {
    if (value == _showThumbnailSidebar) return;
    _showThumbnailSidebar = value;
    _write((s) => s.setBool('${_prefix}showThumbnailSidebar', value));
    notifyListeners();
  }

  /// The saved hand-drawn signature the signature tool stamps, or null
  /// when none has been drawn yet.
  PdfInkSignature? get signature => _signature;

  set signature(PdfInkSignature? value) {
    if (value == _signature) return;
    _signature = value;
    _write((s) => value == null
        ? s.remove('${_prefix}signature')
        : s.setString('${_prefix}signature', value.encode()));
    notifyListeners();
  }

  /// Whether the host shows the annotation list sidebar.
  bool get showAnnotationSidebar => _showAnnotationSidebar;

  set showAnnotationSidebar(bool value) {
    if (value == _showAnnotationSidebar) return;
    _showAnnotationSidebar = value;
    _write((s) => s.setBool('${_prefix}showAnnotationSidebar', value));
    notifyListeners();
  }
}
