import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pdf_document/pdf_document.dart';

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

  /// Drag out a box, then type the rubber-stamp caption (/Stamp).
  stamp,

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
  PdfEditingController(Uint8List bytes, {String password = ''})
      : _bytes = bytes,
        _password = password,
        _revisions = [bytes.length],
        _document = PdfDocument.open(bytes, password: password);

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
    _selected = selected != null && _annotationAt(selected) != null
        ? selected
        : null;
    _invalidateElements();
    notifyListeners();
    return true;
  }

  // ---------------------------------------------------------------------
  // tool state

  PdfEditTool? _tool;
  Color _color = const Color(0xFFE53935);
  double _strokeWidth = 2;
  double _fontSize = 14;
  double _opacity = 1;

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

  /// The color new annotations are created with.
  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    notifyListeners();
  }

  /// Stroke width for ink and shape annotations, in PDF points.
  double get strokeWidth => _strokeWidth;

  set strokeWidth(double value) {
    if (value == _strokeWidth) return;
    _strokeWidth = value;
    notifyListeners();
  }

  /// Font size for free-text annotations, in PDF points.
  double get fontSize => _fontSize;

  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    notifyListeners();
  }

  /// Opacity (0–1] new ink, shape, markup, and stamp annotations are
  /// created with. Free text and notes are always opaque.
  double get opacity => _opacity;

  set opacity(double value) {
    if (value == _opacity) return;
    _opacity = value;
    notifyListeners();
  }

  int get _colorValue => _color.toARGB32() & 0xFFFFFF;

  // ---------------------------------------------------------------------
  // ink

  final Map<int, List<List<(double, double)>>> _ink = {};

  /// Drawn-but-uncommitted ink strokes on [pageIndex], in page space.
  List<List<(double, double)>> strokesOn(int pageIndex) =>
      List.unmodifiable(_ink[pageIndex] ?? const []);

  bool get hasPendingInk => _ink.values.any((s) => s.isNotEmpty);

  /// Buffers one drawn stroke; [finishInk] commits the buffer.
  void addInkStroke(int pageIndex, List<(double, double)> stroke) {
    if (stroke.isEmpty) return;
    _ink.putIfAbsent(pageIndex, () => []).add(List.of(stroke));
    notifyListeners();
  }

  /// Commits the buffered strokes as one Ink annotation per page.
  void finishInk() {
    if (!hasPendingInk) return;
    final strokes = Map.of(_ink);
    _ink.clear();
    apply((editor) {
      strokes.forEach((page, pageStrokes) {
        if (pageStrokes.isNotEmpty) {
          editor.addInk(page, pageStrokes,
              color: _colorValue,
              strokeWidth: _strokeWidth,
              opacity: _opacity);
        }
      });
    });
  }

  /// Throws away the buffered strokes.
  void discardInk() {
    if (_ink.isEmpty) return;
    _ink.clear();
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
                color: _colorValue, opacity: _opacity);
          case PdfMarkupKind.underline:
            editor.addUnderline(page, quads,
                color: _colorValue, opacity: _opacity);
          case PdfMarkupKind.strikeOut:
            editor.addStrikeOut(page, quads,
                color: _colorValue, opacity: _opacity);
          case PdfMarkupKind.squiggly:
            editor.addSquiggly(page, quads,
                color: _colorValue, opacity: _opacity);
        }
      });
    });
  }

  void addRectangle(int pageIndex, PdfRect rect) =>
      apply((e) => e.addSquare(pageIndex, rect,
          strokeColor: _colorValue,
          strokeWidth: _strokeWidth,
          opacity: _opacity));

  void addEllipse(int pageIndex, PdfRect rect) =>
      apply((e) => e.addCircle(pageIndex, rect,
          strokeColor: _colorValue,
          strokeWidth: _strokeWidth,
          opacity: _opacity));

  void addFreeText(int pageIndex, PdfRect rect, String text) =>
      apply((e) => e.addFreeText(pageIndex, rect, text,
          fontSize: _fontSize, color: _colorValue));

  void addStamp(int pageIndex, PdfRect rect, String text) =>
      apply((e) => e.addStamp(pageIndex, rect, text,
          color: _colorValue, opacity: _opacity));

  /// Adds a sticky note with its top-left corner at ([x], [y]).
  void addNote(int pageIndex, double x, double y, String text) =>
      apply((e) => e.addNote(pageIndex, x, y, text, color: _colorValue));

  /// Bakes every page's annotation appearances into its content and
  /// removes the annotations.
  void flattenAllAnnotations() => apply((editor) {
        for (var i = 0; i < _document.pageCount; i++) {
          editor.flattenAnnotations(i);
        }
      });

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
      if (annotation.isHidden ||
          _unselectable.contains(annotation.subtype)) {
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

  /// Rewrites the selected annotation's text: same place, same color, new
  /// text. Implemented as remove + re-add, which regenerates the
  /// appearance stream.
  void setSelectedText(String text) {
    final selected = _selected;
    final annotation = selectedAnnotation;
    if (selected == null || annotation == null || !canEditSelectedText) {
      return;
    }
    final page = selected.$1;
    final rect = annotation.rect;
    final color = annotation.color;
    _selected = null;
    apply((e) {
      e.removeAnnotation(page, annotation);
      switch (annotation.subtype) {
        case 'FreeText':
          final tf = RegExp(r'(\d+(?:\.\d+)?)\s+Tf')
              .firstMatch(annotation.defaultAppearance ?? '');
          e.addFreeText(page, rect, text,
              fontSize: double.tryParse(tf?.group(1) ?? '') ?? _fontSize,
              color: color ?? 0x000000);
        case 'Stamp':
          e.addStamp(page, rect, text, color: color ?? 0xC03030);
        default: // 'Text'
          e.addNote(page, rect.left, rect.top, text, color: color ?? 0xFFD100);
      }
    });
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
