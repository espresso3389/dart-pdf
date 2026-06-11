import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pdf_document/pdf_document.dart';

import 'editing_preferences.dart';
import 'editing_signature.dart';
import 'editing_stamps.dart';

/// The annotation tools a [PdfEditingController] can arm.
///
/// Text markups (highlight, underline, strike-out, squiggly) are not
/// tools — they act on the viewer's current text selection through
/// [PdfEditingController.addMarkup].
enum PdfEditTool {
  /// Tap to select an annotation; drag it to move, drag its handles to
  /// resize.
  select,

  /// Freehand drawing. Strokes accumulate in the controller until
  /// [PdfEditingController.finishInk] commits them as one Ink annotation.
  ink,

  /// Drag out a rectangle (/Square) annotation.
  rectangle,

  /// Drag out an ellipse (/Circle) annotation.
  ellipse,

  /// Drag out a box, then type the text shown inside it (/FreeText).
  freeText,

  /// Tap to place a sticky note (/Text).
  note,

  /// Rubber stamps (/Stamp). With a [PdfEditingController.activeStamp]
  /// a tap places it; otherwise drag out a box and type the caption.
  stamp,

  /// Tap to place the saved hand-drawn signature
  /// ([PdfEditingController.signature]) as an Ink annotation.
  signature,

  /// Tap to select a page content element (text run, path, image); the
  /// selection can be deleted or, for text, rewritten. Edits the page's
  /// content stream itself, not annotations.
  content,
}

/// Text-markup kinds for [PdfEditingController.addMarkup].
enum PdfMarkupKind { highlight, underline, strikeOut, squiggly }

/// An editing session over a PDF document: applies edits through
/// [PdfEditor], owns the resulting document revisions, and carries the
/// UI state of the editing tools (active tool, color, pending ink
/// strokes, selected annotation).
///
/// Every edit is saved as an incremental update, so each revision's bytes
/// are a strict prefix of the next. Undo and redo therefore cost nothing:
/// the controller keeps one byte buffer and a stack of revision lengths,
/// and undoing just reopens the document on a shorter view of the same
/// bytes.
///
/// Pass the controller to [PdfViewer.editing] and rebuild the viewer with
/// [document] when this controller notifies (the document object changes
/// identity on every edit):
///
/// ```dart
/// ListenableBuilder(
///   listenable: editing,
///   builder: (context, _) => PdfViewer(
///     document: editing.document,
///     controller: viewerController,
///     editing: editing,
///   ),
/// )
/// ```
class PdfEditingController extends ChangeNotifier {
  PdfEditingController(Uint8List bytes,
      {String password = '', PdfEditingPreferences? preferences})
      : _bytes = bytes,
        _password = password,
        _revisions = [bytes.length],
        _document = PdfDocument.open(bytes, password: password),
        preferences = preferences ?? PdfEditingPreferences() {
    this.preferences.addListener(notifyListeners);
  }

  /// The persisted UI preferences backing [color], [strokeWidth],
  /// [fontSize], [opacity], and [fingerDrawsInk] — every change is saved
  /// to the local device and restored on the next session. Pass one in
  /// to share it with the host's chrome (the sidebar-visibility flags
  /// live there too).
  final PdfEditingPreferences preferences;

  @override
  void dispose() {
    preferences.removeListener(notifyListeners);
    super.dispose();
  }

  final String _password;

  /// The full byte buffer; revisions are prefixes of it.
  Uint8List _bytes;

  /// Byte length of each revision, oldest first. `_revisions[_cursor]`
  /// is the current one; entries past the cursor are redoable.
  final List<int> _revisions;
  int _cursor = 0;

  PdfDocument _document;

  /// The document at the current revision. Changes identity on every
  /// edit, undo, and redo.
  PdfDocument get document => _document;

  /// The current revision's bytes — what "save to disk" should write.
  Uint8List get bytes => Uint8List.sublistView(_bytes, 0, _revisions[_cursor]);

  /// Whether the current revision differs from the originally opened one.
  bool get isModified => _cursor > 0;

  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _revisions.length - 1;

  void undo() {
    if (!canUndo) return;
    _cursor--;
    _reopen();
  }

  void redo() {
    if (!canRedo) return;
    _cursor++;
    _reopen();
  }

  void _reopen() {
    _document = PdfDocument.open(bytes, password: _password);
    // the same /Annots slot may hold a different annotation now
    _selected = null;
    _invalidateElements();
    notifyListeners();
  }

  /// Runs [edit] against the current document and commits the result as a
  /// new revision. Returns false (and changes nothing) if [edit] staged no
  /// changes. Redoable revisions are discarded, like any editor's redo
  /// stack on a fresh edit.
  bool apply(void Function(PdfEditor editor) edit) {
    final editor = PdfEditor(_document);
    edit(editor);
    if (!editor.hasChanges) return false;
    final saved = editor.save();
    _revisions.removeRange(_cursor + 1, _revisions.length);
    _bytes = saved;
    _revisions.add(saved.length);
    _cursor++;
    final selected = _selected;
    _document = PdfDocument.open(bytes, password: _password);
    // annotations keep their /Annots slot across move/resize edits, so a
    // still-valid selection survives the document swap
    _selected =
        selected != null && _annotationAt(selected) != null ? selected : null;
    _invalidateElements();
    notifyListeners();
    return true;
  }

  // ---------------------------------------------------------------------
  // tool state

  PdfEditTool? _tool;

  /// The armed tool, or null when the viewer behaves as a plain reader.
  PdfEditTool? get tool => _tool;

  set tool(PdfEditTool? value) {
    if (value == _tool) return;
    // leaving the ink tool commits the drawing, like lifting the pen
    if (_tool == PdfEditTool.ink && value != PdfEditTool.ink) finishInk();
    _tool = value;
    if (value != PdfEditTool.select) _selected = null;
    if (value != PdfEditTool.content) _selectedElement = null;
    notifyListeners();
  }

  /// The color new annotations are created with. Persisted (these four
  /// style properties live in [preferences]).
  Color get color => preferences.color;

  set color(Color value) => preferences.color = value;

  /// Stroke width for ink and shape annotations, in PDF points. Persisted.
  double get strokeWidth => preferences.strokeWidth;

  set strokeWidth(double value) => preferences.strokeWidth = value;

  /// Font size for free-text annotations, in PDF points. Persisted.
  double get fontSize => preferences.fontSize;

  set fontSize(double value) => preferences.fontSize = value;

  /// Font family for free-text annotations — one of the standard PDF
  /// text fonts (sans-serif, serif, monospace). Persisted.
  PdfStandardFont get fontFamily => preferences.fontFamily;

  set fontFamily(PdfStandardFont value) => preferences.fontFamily = value;

  /// Opacity (0–1] new ink, shape, markup, and stamp annotations are
  /// created with. Free text and notes are always opaque. Persisted.
  double get opacity => preferences.opacity;

  set opacity(double value) => preferences.opacity = value;

  int get _colorValue => preferences.color.toARGB32() & 0xFFFFFF;

  /// The author name new annotations carry (/T — shown in
  /// [PdfAnnotationSidebar] and other viewers' comment lists). Null
  /// (the default) leaves them unsigned. Persisted.
  String? get author => preferences.author;

  set author(String? value) => preferences.author = value;

  // ---------------------------------------------------------------------
  // in-place text editing

  bool _editingText = false;

  /// Whether an in-place text editor (the free-text tool's box) is open
  /// on a page. While it is, the viewer releases its keyboard shortcuts —
  /// backspace must delete characters, not the annotation.
  bool get isEditingText => _editingText;

  /// Marks an in-place text editor open/closed. Called by the page
  /// overlay that owns the editor.
  void setEditingText(bool value) {
    if (value == _editingText) return;
    _editingText = value;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // eyedropper

  bool _pickingColor = false;

  /// Whether the eyedropper is armed: the next tap on a page samples the
  /// rendered color there and becomes [color].
  bool get isPickingColor => _pickingColor;

  /// Arms the eyedropper. The viewer's page overlays take the next tap.
  void startColorPick() {
    if (_pickingColor) return;
    _pickingColor = true;
    notifyListeners();
  }

  void cancelColorPick() {
    if (!_pickingColor) return;
    _pickingColor = false;
    notifyListeners();
  }

  /// Disarms the eyedropper and adopts [picked] (forced opaque — alpha is
  /// [opacity]'s job) as the annotation [color].
  void finishColorPick(Color picked) {
    _pickingColor = false;
    preferences.color = Color(0xFF000000 | (picked.toARGB32() & 0xFFFFFF));
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // ink

  final Map<int, List<List<(double, double)>>> _ink = {};
  final Map<int, List<List<double>?>> _inkPressures = {};

  /// Whether touch pointers draw with the ink tool. When false they
  /// scroll and zoom as usual and only stylus (and mouse) input draws —
  /// palm rejection. The viewer turns this off automatically the first
  /// time a stylus (Apple Pencil) touches a page with the ink tool armed,
  /// and the choice is persisted with the other [preferences].
  bool get fingerDrawsInk => preferences.fingerDrawsInk;

  set fingerDrawsInk(bool value) => preferences.fingerDrawsInk = value;

  /// Drawn-but-uncommitted ink strokes on [pageIndex], in page space.
  List<List<(double, double)>> strokesOn(int pageIndex) =>
      List.unmodifiable(_ink[pageIndex] ?? const []);

  /// Per-point normalized pressures paralleling [strokesOn] — null for
  /// strokes drawn without pressure (finger, mouse).
  List<List<double>?> strokePressuresOn(int pageIndex) =>
      List.unmodifiable(_inkPressures[pageIndex] ?? const []);

  bool get hasPendingInk => _ink.values.any((s) => s.isNotEmpty);

  /// Buffers one drawn stroke; [finishInk] commits the buffer.
  /// [pressures], when given, must hold one 0–1 value per stroke point.
  void addInkStroke(int pageIndex, List<(double, double)> stroke,
      {List<double>? pressures}) {
    if (stroke.isEmpty) return;
    assert(pressures == null || pressures.length == stroke.length);
    _ink.putIfAbsent(pageIndex, () => []).add(List.of(stroke));
    _inkPressures
        .putIfAbsent(pageIndex, () => [])
        .add(pressures == null ? null : List.of(pressures));
    notifyListeners();
  }

  /// Commits the buffered strokes as one Ink annotation per page.
  void finishInk() {
    if (!hasPendingInk) return;
    final strokes = Map.of(_ink);
    final pressures = Map.of(_inkPressures);
    _ink.clear();
    _inkPressures.clear();
    apply((editor) {
      strokes.forEach((page, pageStrokes) {
        if (pageStrokes.isNotEmpty) {
          editor.addInk(page, pageStrokes,
              color: _colorValue,
              strokeWidth: preferences.strokeWidth,
              opacity: preferences.opacity,
              pressures: pressures[page],
              author: author);
        }
      });
    });
  }

  /// Throws away the buffered strokes.
  void discardInk() {
    if (_ink.isEmpty) return;
    _ink.clear();
    _inkPressures.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // creation

  /// Adds a text markup of [kind] over [quadsByPage] (page index → quad
  /// rects, e.g. from [PdfViewerController.selectionRectsOn]).
  void addMarkup(PdfMarkupKind kind, Map<int, List<PdfRect>> quadsByPage) {
    if (quadsByPage.values.every((quads) => quads.isEmpty)) return;
    apply((editor) {
      quadsByPage.forEach((page, quads) {
        if (quads.isEmpty) return;
        switch (kind) {
          case PdfMarkupKind.highlight:
            editor.addHighlight(page, quads,
                color: _colorValue,
                opacity: preferences.opacity,
                author: author);
          case PdfMarkupKind.underline:
            editor.addUnderline(page, quads,
                color: _colorValue,
                opacity: preferences.opacity,
                author: author);
          case PdfMarkupKind.strikeOut:
            editor.addStrikeOut(page, quads,
                color: _colorValue,
                opacity: preferences.opacity,
                author: author);
          case PdfMarkupKind.squiggly:
            editor.addSquiggly(page, quads,
                color: _colorValue,
                opacity: preferences.opacity,
                author: author);
        }
      });
    });
  }

  void addRectangle(int pageIndex, PdfRect rect) =>
      apply((e) => e.addSquare(pageIndex, rect,
          strokeColor: _colorValue,
          strokeWidth: preferences.strokeWidth,
          opacity: preferences.opacity,
          author: author));

  void addEllipse(int pageIndex, PdfRect rect) =>
      apply((e) => e.addCircle(pageIndex, rect,
          strokeColor: _colorValue,
          strokeWidth: preferences.strokeWidth,
          opacity: preferences.opacity,
          author: author));

  void addFreeText(int pageIndex, PdfRect rect, String text) =>
      apply((e) => e.addFreeText(pageIndex, rect, text,
          fontSize: preferences.fontSize,
          font: preferences.fontFamily,
          color: _colorValue,
          author: author));

  void addStamp(int pageIndex, PdfRect rect, String text, {int? color}) =>
      apply((e) => e.addStamp(pageIndex, rect, text,
          color: color ?? _colorValue,
          opacity: preferences.opacity,
          author: author));

  /// Adds a sticky note with its top-left corner at ([x], [y]).
  void addNote(int pageIndex, double x, double y, String text) => apply((e) =>
      e.addNote(pageIndex, x, y, text, color: _colorValue, author: author));

  // ---------------------------------------------------------------------
  // signature

  /// The saved hand-drawn signature the signature tool stamps. Persisted
  /// with the other [preferences], so it survives app restarts. Drawn in
  /// [showPdfSignatureDialog].
  PdfInkSignature? get signature => preferences.signature;

  set signature(PdfInkSignature? value) => preferences.signature = value;

  /// Stamps [signature] as an Ink annotation centered on ([x], [y]) in
  /// page space, [width] points wide (clamped, with the center, so the
  /// whole signature stays on the page). Keeps the signature's own ink
  /// color and pen pressures. Returns false when none is saved.
  bool placeSignature(int pageIndex, double x, double y, {double width = 160}) {
    final signature = preferences.signature;
    if (signature == null) return false;
    final box = _document.page(pageIndex).cropBox;
    final aspect = signature.aspect > 0 ? signature.aspect : 2.0;
    var w = width.clamp(8.0, box.width * 0.9);
    var h = w / aspect;
    if (h > box.height * 0.9) {
      h = box.height * 0.9;
      w = h * aspect;
    }
    final cx = x.clamp(box.left + w / 2, box.right - w / 2);
    final cy = y.clamp(box.bottom + h / 2, box.top - h / 2);
    final left = cx - w / 2, top = cy + h / 2;
    final strokes = [
      for (final stroke in signature.strokes)
        [
          // normalized pad space is y-down; page space is y-up
          for (final (nx, ny) in stroke) (left + nx * w, top - ny * h)
        ]
    ];
    return apply((e) => e.addInk(pageIndex, strokes,
        color: signature.color,
        strokeWidth: w / 75, // pen-like: ~2pt at the default width
        opacity: 1,
        pressures: signature.pressures,
        author: author));
  }

  // ---------------------------------------------------------------------
  // custom stamps

  /// The user's saved custom stamps. Persisted with the other
  /// [preferences], so they survive app restarts. Created in
  /// [showPdfStampEditor] (usually via the picker, [showPdfStampPicker]).
  List<PdfCustomStamp> get customStamps => preferences.customStamps;

  /// Appends [stamp] to the saved list.
  void saveCustomStamp(PdfCustomStamp stamp) =>
      preferences.customStamps = [...preferences.customStamps, stamp];

  /// Removes [stamp] from the saved list. If it was the active stamp,
  /// the stamp tool falls back to prompting for text.
  void removeCustomStamp(PdfCustomStamp stamp) {
    preferences.customStamps = [
      for (final saved in preferences.customStamps)
        if (saved != stamp) saved
    ];
    if (_activeStamp == stamp) {
      _activeStamp = null;
      notifyListeners();
    }
  }

  PdfCustomStamp? _activeStamp;

  /// The custom stamp the stamp tool places on tap. Null means the
  /// classic flow: drag out a box and type the caption. Not persisted —
  /// each session starts in the classic flow.
  PdfCustomStamp? get activeStamp => _activeStamp;

  set activeStamp(PdfCustomStamp? value) {
    if (value == _activeStamp) return;
    _activeStamp = value;
    notifyListeners();
  }

  /// Places [activeStamp] centered on ([x], [y]) in page space,
  /// [height] points tall and auto-sized from its caption (clamped,
  /// with the center, so the whole stamp stays on the page). Returns
  /// false when no stamp is active.
  bool placeStamp(int pageIndex, double x, double y, {double height = 40}) {
    final stamp = _activeStamp;
    if (stamp == null) return false;
    final box = _document.page(pageIndex).cropBox;
    final h = height.clamp(8.0, box.height * 0.9);
    // mirror addStamp's appearance math (6pt padding, text 72% of the
    // height) so the caption fills the box without shrinking
    final fontSize = (h - 12) * 0.72;
    final w = (measureHelvetica(stamp.text, fontSize, bold: true) + 24)
        .clamp(h, box.width * 0.9);
    final cx = x.clamp(box.left + w / 2, box.right - w / 2);
    final cy = y.clamp(box.bottom + h / 2, box.top - h / 2);
    return apply((e) => e.addStamp(pageIndex,
        PdfRect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), stamp.text,
        color: stamp.color, opacity: preferences.opacity, author: author));
  }

  /// Bakes every page's annotation appearances into its content and
  /// removes the annotations.
  void flattenAllAnnotations() => apply((editor) {
        for (var i = 0; i < _document.pageCount; i++) {
          editor.flattenAnnotations(i);
        }
      });

  // ---------------------------------------------------------------------
  // pages

  /// Moves the page at [from] so it ends up at index [to]. Structural
  /// page edits shift page indices, so the annotation selection (a
  /// page-indexed slot) is cleared first.
  void movePage(int from, int to) {
    if (from == to) return;
    _selected = null;
    apply((e) => e.movePage(from, to));
  }

  /// Removes the page at [index]. Refused (a no-op) on the last page —
  /// a document must keep at least one.
  void removePage(int index) {
    if (_document.pageCount <= 1) return;
    _selected = null;
    apply((e) => e.removePage(index));
  }

  // ---------------------------------------------------------------------
  // selection

  /// Annotation subtypes the select tool ignores: popups belong to their
  /// parent, links and widgets are interactive objects with their own
  /// semantics (widgets are form fields — moving one breaks its field).
  static const _unselectable = {'Popup', 'Link', 'Widget'};

  /// Subtypes whose geometry is defined by /Rect (plus point arrays the
  /// editor rescales), so resizing keeps them consistent everywhere.
  static const _resizable = {'Square', 'Circle', 'FreeText', 'Stamp', 'Ink'};

  /// Subtypes whose text the controller can rewrite in place.
  static const _textEditable = {'FreeText', 'Stamp', 'Text'};

  (int page, int index)? _selected;

  PdfAnnotation? _annotationAt((int, int) selected) {
    final (page, index) = selected;
    if (page < 0 || page >= _document.pageCount) return null;
    final annotations = _document.page(page).annotations;
    return index < annotations.length ? annotations[index] : null;
  }

  /// The selected annotation, resolved against the current revision.
  PdfAnnotation? get selectedAnnotation {
    final selected = _selected;
    return selected == null ? null : _annotationAt(selected);
  }

  /// The page the selected annotation lives on.
  int? get selectedPage => selectedAnnotation == null ? null : _selected!.$1;

  /// (pageIndex, /Annots slot) of the selected annotation, for comparing
  /// against a list position (the annotation sidebar's selected tile).
  (int page, int index)? get selectedAnnotationSlot =>
      selectedAnnotation == null ? null : _selected;

  bool get canResizeSelected =>
      _resizable.contains(selectedAnnotation?.subtype);

  /// Rotation rides the appearance stream's /Matrix, so it needs one.
  bool get canRotateSelected =>
      _resizable.contains(selectedAnnotation?.subtype) &&
      selectedAnnotation?.normalAppearance != null;

  bool get canEditSelectedText =>
      _textEditable.contains(selectedAnnotation?.subtype);

  /// Selects the topmost selectable annotation under ([x], [y]) on
  /// [pageIndex]; clears the selection when nothing is hit. Returns
  /// whether an annotation was selected.
  bool selectAnnotationAt(int pageIndex, double x, double y) {
    final annotations = _document.page(pageIndex).annotations;
    // later /Annots entries draw on top, so they win the hit test
    for (var i = annotations.length - 1; i >= 0; i--) {
      final annotation = annotations[i];
      if (annotation.isHidden || _unselectable.contains(annotation.subtype)) {
        continue;
      }
      if (annotation.rect.contains(x, y)) {
        if (_selected != (pageIndex, i)) {
          _selected = (pageIndex, i);
          notifyListeners();
        }
        return true;
      }
    }
    clearAnnotationSelection();
    return false;
  }

  /// Selects the annotation in slot [index] of [pageIndex]'s /Annots
  /// (the position in [PdfPage.annotations]), arming the select tool so
  /// the viewer shows the selection. Used by the annotation sidebar.
  /// Returns false for invalid slots and unselectable subtypes.
  bool selectAnnotation(int pageIndex, int index) {
    final annotation = _annotationAt((pageIndex, index));
    if (annotation == null || _unselectable.contains(annotation.subtype)) {
      return false;
    }
    tool = PdfEditTool.select;
    if (_selected != (pageIndex, index)) {
      _selected = (pageIndex, index);
      notifyListeners();
    }
    return true;
  }

  /// Removes the annotation in slot [index] of [pageIndex]'s /Annots
  /// without going through the selection.
  void deleteAnnotation(int pageIndex, int index) {
    final annotation = _annotationAt((pageIndex, index));
    if (annotation == null) return;
    if (_selected == (pageIndex, index)) _selected = null;
    apply((e) => e.removeAnnotation(pageIndex, annotation));
  }

  /// Removes several annotations — (pageIndex, /Annots slot) pairs — in
  /// one revision, so a single undo restores them all. Invalid slots are
  /// skipped. Used by the annotation sidebar's multi-select delete.
  void deleteAnnotations(Iterable<(int page, int index)> slots) {
    // resolve every slot before the first removal shifts the others
    final targets = <(int, PdfAnnotation)>[
      for (final slot in slots)
        if (_annotationAt(slot) case final annotation?) (slot.$1, annotation)
    ];
    if (targets.isEmpty) return;
    // surviving annotations may land in different slots
    _selected = null;
    apply((e) {
      for (final (page, annotation) in targets) {
        e.removeAnnotation(page, annotation);
      }
    });
  }

  void clearAnnotationSelection() {
    if (_selected == null) return;
    _selected = null;
    notifyListeners();
  }

  /// Translates the selected annotation by ([dx], [dy]) in page space.
  /// The selection survives: the annotation keeps its /Annots slot.
  void moveSelected(double dx, double dy) {
    final annotation = selectedAnnotation;
    if (annotation == null) return;
    apply((e) => e.moveAnnotation(_selected!.$1, annotation, dx, dy));
  }

  /// Resizes the selected annotation so its /Rect becomes [to].
  void resizeSelected(PdfRect to) {
    final annotation = selectedAnnotation;
    if (annotation == null || !canResizeSelected) return;
    if (to.width < 1 || to.height < 1) return;
    apply((e) => e.resizeAnnotation(_selected!.$1, annotation, to));
  }

  /// Rotates the selected annotation by [degrees] counterclockwise (page
  /// space) about its center. The selection keeps its /Annots slot.
  void rotateSelected(double degrees) {
    final annotation = selectedAnnotation;
    if (annotation == null || !canRotateSelected) return;
    if (degrees.abs() < 0.01) return;
    apply((e) => e.rotateAnnotation(_selected!.$1, annotation, degrees));
  }

  /// Deletes whatever is selected: the content element when the content
  /// tool has one, otherwise the selected annotation.
  void deleteSelected() {
    if (_selectedElement != null) {
      deleteSelectedElement();
      return;
    }
    final selected = _selected;
    final annotation = selectedAnnotation;
    if (selected == null || annotation == null) return;
    _selected = null;
    apply((e) => e.removeAnnotation(selected.$1, annotation));
  }

  /// The selected annotation's text, for pre-filling an edit prompt.
  String? get selectedText => selectedAnnotation?.contents;

  /// Parses a free-text annotation's /DA: the font it was written with
  /// and its size, falling back to the current preferences.
  ({PdfStandardFont font, double size}) _freeTextStyleOf(
      PdfAnnotation annotation) {
    final tf = RegExp(r'/(\S+)\s+(\d+(?:\.\d+)?)\s+Tf')
        .firstMatch(annotation.defaultAppearance ?? '');
    return (
      font: tf == null
          ? preferences.fontFamily
          : PdfStandardFont.fromName(tf.group(1)!),
      size: double.tryParse(tf?.group(2) ?? '') ?? preferences.fontSize,
    );
  }

  /// Whether the selection is a free-text annotation whose font and size
  /// [restyleSelectedText] can change.
  bool get canRestyleSelectedText => selectedAnnotation?.subtype == 'FreeText';

  /// The selected free-text annotation's font and size (parsed from its
  /// /DA), or null when the selection isn't free text.
  ({PdfStandardFont font, double size})? get selectedTextStyle {
    final annotation = selectedAnnotation;
    if (annotation?.subtype != 'FreeText') return null;
    return _freeTextStyleOf(annotation!);
  }

  /// Rewrites the selected free-text annotation with a new [font] and/or
  /// [size], keeping its text, place, color, and author. The selection
  /// survives (the annotation keeps its /Annots slot).
  void restyleSelectedText({PdfStandardFont? font, double? size}) {
    final annotation = selectedAnnotation;
    if (annotation == null || !canRestyleSelectedText) return;
    final style = _freeTextStyleOf(annotation);
    _rewriteSelected(annotation, annotation.contents ?? '',
        font: font ?? style.font, size: size ?? style.size);
  }

  /// Rewrites the selected annotation's text: same place, same style, new
  /// text. Implemented as remove + re-add, which regenerates the
  /// appearance stream.
  void setSelectedText(String text) {
    final annotation = selectedAnnotation;
    if (annotation == null || !canEditSelectedText) return;
    _rewriteSelected(annotation, text);
  }

  void _rewriteSelected(PdfAnnotation annotation, String text,
      {PdfStandardFont? font, double? size}) {
    final selected = _selected;
    if (selected == null) return;
    final page = selected.$1;
    final rect = annotation.rect;
    final color = annotation.color;
    final by = annotation.author; // a text edit doesn't change ownership
    _selected = null;
    apply((e) {
      e.removeAnnotation(page, annotation);
      switch (annotation.subtype) {
        case 'FreeText':
          final style = _freeTextStyleOf(annotation);
          e.addFreeText(page, rect, text,
              fontSize: size ?? style.size,
              font: font ?? style.font,
              color: color ?? 0x000000,
              author: by);
        case 'Stamp':
          e.addStamp(page, rect, text, color: color ?? 0xC03030, author: by);
        default: // 'Text'
          e.addNote(page, rect.left, rect.top, text,
              color: color ?? 0xFFD100, author: by);
      }
    });
    // the rewritten annotation lands in the last /Annots slot — keep it
    // selected so consecutive restyles (a settings popup) stay anchored
    final annotations = _document.page(page).annotations;
    if (annotations.isNotEmpty) {
      _selected = (page, annotations.length - 1);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // content elements

  /// Parsed page elements, cached per page for the current revision.
  final Map<int, PdfPageElements> _elements = {};

  /// (pageIndex, element id) of the selected content element. Element ids
  /// only mean anything within one revision, so any edit clears this.
  (int page, int id)? _selectedElement;

  void _invalidateElements() {
    _elements.clear();
    _selectedElement = null;
  }

  /// The content elements of [pageIndex] at the current revision.
  PdfPageElements elementsOn(int pageIndex) => _elements.putIfAbsent(
      pageIndex, () => PdfPageElements.of(_document, pageIndex));

  /// The selected content element, or null.
  PdfContentElement? get selectedElement {
    final selected = _selectedElement;
    if (selected == null) return null;
    final elements = elementsOn(selected.$1).elements;
    return selected.$2 < elements.length ? elements[selected.$2] : null;
  }

  /// The page the selected content element lives on.
  int? get selectedElementPage =>
      selectedElement == null ? null : _selectedElement!.$1;

  /// Whether the selected element is a text run whose characters the
  /// controller can rewrite.
  bool get canEditSelectedElementText =>
      selectedElement?.kind == PdfElementKind.text &&
      (selectedElement?.text?.isNotEmpty ?? false);

  /// Selects the topmost content element whose bounds contain ([x], [y])
  /// on [pageIndex]; clears the selection when nothing is hit. Bounds are
  /// approximate (see [PdfContentElement.bounds]).
  bool selectElementAt(int pageIndex, double x, double y) {
    final hits = elementsOn(pageIndex).elementsAt(x, y);
    if (hits.isEmpty) {
      clearElementSelection();
      return false;
    }
    final hit = (pageIndex, hits.first.id);
    if (_selectedElement != hit) {
      _selectedElement = hit;
      notifyListeners();
    }
    return true;
  }

  void clearElementSelection() {
    if (_selectedElement == null) return;
    _selectedElement = null;
    notifyListeners();
  }

  /// Deletes the selected content element from its page's content stream.
  void deleteSelectedElement() {
    final selected = _selectedElement;
    final element = selectedElement;
    if (selected == null || element == null) return;
    apply((e) => e.deleteElements(elementsOn(selected.$1), [element.id]));
  }

  /// Rewrites the selected text element's characters to [text] and
  /// returns how many text runs changed.
  ///
  /// Built on [PdfEditor.replaceText], so its limits apply: identical
  /// runs elsewhere on the page change too, composite (Type0) fonts are
  /// skipped, and glyphs are not re-measured — longer replacements can
  /// overlap what follows on the line.
  int replaceSelectedElementText(String text) {
    final selected = _selectedElement;
    final element = selectedElement;
    if (selected == null || element == null || !canEditSelectedElementText) {
      return 0;
    }
    var count = 0;
    apply((e) => count = e.replaceText(selected.$1, element.text!, text));
    return count;
  }
}
