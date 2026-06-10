part of 'editor.dart';

/// Annotation authoring (§12.5): each method creates an annotation with a
/// generated appearance stream (/AP → /N), so the result displays the same
/// in this renderer and in other viewers.
///
/// Colors are `0xRRGGBB` ints; coordinates are PDF user space (origin at
/// the page's bottom-left, y up). Annotations are staged on the editor and
/// written by [PdfEditor.save].
extension PdfAnnotationEditing on PdfEditor {
  /// Adds a text-markup highlight over [quads] (one rect per marked word,
  /// line, or column slice).
  ///
  /// The appearance paints the quads in [color] with Multiply blending, the
  /// conventional highlighter look that keeps text underneath readable.
  void addHighlight(
    int pageIndex,
    List<PdfRect> quads, {
    int color = 0xFFD100,
    double opacity = 1,
    String? contents,
    String? author,
  }) {
    final rect = _boundsOf(quads);
    final w = ContentWriter()
      ..extGState('GS0')
      ..fillColor(color);
    for (final q in quads) {
      w.rect(q.left, q.bottom, q.width, q.height);
    }
    w.fill();
    _addAnnotation(
      pageIndex,
      _markupDict('Highlight', rect, color, contents, author)
        ..['QuadPoints'] = _quadPoints(quads),
      _form(rect, w,
          resources: _resources(
              extGState: _alphaState(opacity, multiply: true))),
    );
  }

  /// Adds an underline beneath each quad in [quads].
  void addUnderline(int pageIndex, List<PdfRect> quads,
          {int color = 0x10A010,
          double opacity = 1,
          String? contents,
          String? author}) =>
      _addLineMarkup('Underline', pageIndex, quads, color, opacity, contents,
          author, atHeight: 0.08);

  /// Adds a strike-out through each quad in [quads].
  void addStrikeOut(int pageIndex, List<PdfRect> quads,
          {int color = 0xD02020,
          double opacity = 1,
          String? contents,
          String? author}) =>
      _addLineMarkup('StrikeOut', pageIndex, quads, color, opacity, contents,
          author, atHeight: 0.45);

  /// Adds a squiggly (jagged) underline beneath each quad in [quads].
  void addSquiggly(int pageIndex, List<PdfRect> quads,
      {int color = 0xD02020,
      double opacity = 1,
      String? contents,
      String? author}) {
    final rect = _boundsOf(quads);
    final w = ContentWriter()..strokeColor(color);
    final gs = _alphaState(opacity);
    if (gs != null) w.extGState('GS0');
    for (final q in quads) {
      final amplitude = q.height * 0.1;
      final period = q.height * 0.3;
      w.lineWidth((q.height * 0.05).clamp(0.5, 2.0));
      w.moveTo(q.left, q.bottom + amplitude);
      var up = true;
      for (var x = q.left + period / 2; x < q.right; x += period / 2) {
        w.lineTo(x, q.bottom + (up ? amplitude * 2 : 0));
        up = !up;
      }
      w.stroke();
    }
    _addAnnotation(
      pageIndex,
      _markupDict('Squiggly', rect, color, contents, author)
        ..['QuadPoints'] = _quadPoints(quads),
      _form(rect, w, resources: _resources(extGState: gs)),
    );
  }

  /// Adds a freehand ink annotation. Each stroke is a polyline of
  /// `(x, y)` points in page space.
  void addInk(
    int pageIndex,
    List<List<(double, double)>> strokes, {
    int color = 0xD02020,
    double strokeWidth = 2,
    double opacity = 1,
    String? contents,
    String? author,
  }) {
    if (strokes.isEmpty || strokes.any((s) => s.isEmpty)) {
      throw ArgumentError.value(strokes, 'strokes', 'must be non-empty');
    }
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final stroke in strokes) {
      for (final (x, y) in stroke) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    final pad = strokeWidth / 2 + 1;
    final rect =
        PdfRect(minX - pad, minY - pad, maxX + pad, maxY + pad);

    final w = ContentWriter();
    final gs = _alphaState(opacity);
    if (gs != null) w.extGState('GS0');
    w
      ..strokeColor(color)
      ..lineWidth(strokeWidth)
      ..roundLines();
    for (final stroke in strokes) {
      final (x0, y0) = stroke.first;
      w.moveTo(x0, y0);
      if (stroke.length == 1) {
        // a dot: zero-length segment with round caps paints a circle
        w.lineTo(x0, y0);
      }
      for (final (x, y) in stroke.skip(1)) {
        w.lineTo(x, y);
      }
      w.stroke();
    }

    _addAnnotation(
      pageIndex,
      _markupDict('Ink', rect, color, contents, author)
        ..['BS'] = _borderStyle(strokeWidth)
        ..['InkList'] = CosArray([
          for (final stroke in strokes)
            CosArray([
              for (final (x, y) in stroke) ...[CosReal(x), CosReal(y)],
            ]),
        ]),
      _form(rect, w, resources: _resources(extGState: gs)),
    );
  }

  /// Adds a rectangle annotation. At least one of [strokeColor] and
  /// [fillColor] must be given.
  void addSquare(
    int pageIndex,
    PdfRect rect, {
    int? strokeColor = 0xD02020,
    double strokeWidth = 2,
    int? fillColor,
    double opacity = 1,
    String? contents,
    String? author,
  }) =>
      _addShape('Square', pageIndex, rect, strokeColor, strokeWidth,
          fillColor, opacity, contents, author);

  /// Adds an ellipse annotation inscribed in [rect]. At least one of
  /// [strokeColor] and [fillColor] must be given.
  void addCircle(
    int pageIndex,
    PdfRect rect, {
    int? strokeColor = 0xD02020,
    double strokeWidth = 2,
    int? fillColor,
    double opacity = 1,
    String? contents,
    String? author,
  }) =>
      _addShape('Circle', pageIndex, rect, strokeColor, strokeWidth,
          fillColor, opacity, contents, author);

  /// Adds a free-text annotation: [text] rendered directly on the page in
  /// 12pt-default Helvetica, wrapped to fit [rect] and clipped to it.
  void addFreeText(
    int pageIndex,
    PdfRect rect,
    String text, {
    double fontSize = 12,
    int color = 0x000000,
    int? fillColor,
    int? borderColor,
    double borderWidth = 1,
    String? author,
  }) {
    const pad = 3.0;
    final w = ContentWriter();
    if (fillColor != null) {
      w
        ..fillColor(fillColor)
        ..rect(rect.left, rect.bottom, rect.width, rect.height)
        ..fill();
    }
    if (borderColor != null && borderWidth > 0) {
      w
        ..strokeColor(borderColor)
        ..lineWidth(borderWidth)
        ..rect(rect.left + borderWidth / 2, rect.bottom + borderWidth / 2,
            rect.width - borderWidth, rect.height - borderWidth)
        ..stroke();
    }
    w
      ..save()
      ..rect(rect.left, rect.bottom, rect.width, rect.height)
      ..clip()
      ..beginText()
      ..font('Helv', fontSize)
      ..leading(fontSize * 1.2)
      ..fillColor(color)
      // Helvetica ascender is 718/1000 em — first baseline sits one
      // ascent below the top padding
      ..textAt(rect.left + pad, rect.top - pad - fontSize * 0.718);
    final lines = _wrap(text, fontSize, rect.width - 2 * pad);
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) w.nextLine();
      w.showText(lines[i]);
    }
    w
      ..endText()
      ..restore();

    final da = '${ContentWriter.rgbComponents(color).map(ContentWriter.fmt).join(' ')} rg '
        '/Helv ${ContentWriter.fmt(fontSize)} Tf';
    _addAnnotation(
      pageIndex,
      _markupDict('FreeText', rect, color, text, author)
        ..['DA'] = CosString.fromText(da)
        ..['Q'] = const CosInteger(0),
      _form(rect, w, resources: _resources(font: _helvetica())),
    );
  }

  /// Adds a sticky-note (/Text) annotation with its top-left corner at
  /// ([x], [y]). Viewers show [contents] in a popup when it is opened.
  void addNote(
    int pageIndex,
    double x,
    double y,
    String contents, {
    int color = 0xFFD100,
    String? author,
  }) {
    const size = 20.0;
    final rect = PdfRect(x, y - size, x + size, y);
    final w = ContentWriter()
      // note sheet
      ..fillColor(color)
      ..strokeColor(0x404040)
      ..lineWidth(1)
      ..roundedRect(x + 1, y - size + 1, size - 2, size - 2, 2)
      ..fillAndStroke()
      // text lines on the sheet
      ..strokeColor(0x606060)
      ..lineWidth(1);
    for (var i = 0; i < 3; i++) {
      final lineY = y - 6 - i * 4;
      w
        ..moveTo(x + 4, lineY)
        ..lineTo(x + size - 4, lineY)
        ..stroke();
    }
    _addAnnotation(
      pageIndex,
      _markupDict('Text', rect, color, contents, author)
        ..['Name'] = const CosName('Comment'),
      _form(rect, w),
    );
  }

  /// Adds a rubber-stamp annotation: [text] centered in bold inside a
  /// rounded border, sized to fit [rect].
  void addStamp(
    int pageIndex,
    PdfRect rect,
    String text, {
    int color = 0xC03030,
    double opacity = 1,
    String? author,
  }) {
    const borderWidth = 2.0;
    const pad = 6.0;
    var fontSize = (rect.height - 2 * pad) * 0.72;
    final available = rect.width - 2 * pad;
    final atUnit = measureHelvetica(text, 1, bold: true);
    if (atUnit > 0 && atUnit * fontSize > available) {
      fontSize = available / atUnit;
    }
    final textWidth = atUnit * fontSize;

    final w = ContentWriter();
    final gs = _alphaState(opacity);
    if (gs != null) w.extGState('GS0');
    w
      ..strokeColor(color)
      ..lineWidth(borderWidth)
      ..roundedRect(rect.left + borderWidth / 2, rect.bottom + borderWidth / 2,
          rect.width - borderWidth, rect.height - borderWidth, 4)
      ..stroke()
      ..beginText()
      ..font('HelvB', fontSize)
      ..fillColor(color)
      ..textAt(rect.left + (rect.width - textWidth) / 2,
          rect.bottom + (rect.height - fontSize * 0.718) / 2)
      ..showText(text)
      ..endText();

    _addAnnotation(
      pageIndex,
      _markupDict('Stamp', rect, color, text, author),
      _form(rect, w,
          resources: _resources(
              extGState: gs,
              font: _helvetica(bold: true, name: 'HelvB'))),
    );
  }

  // ---------------------------------------------------------------------
  // shared machinery

  void _addLineMarkup(
    String subtype,
    int pageIndex,
    List<PdfRect> quads,
    int color,
    double opacity,
    String? contents,
    String? author, {
    required double atHeight,
  }) {
    final rect = _boundsOf(quads);
    final w = ContentWriter();
    final gs = _alphaState(opacity);
    if (gs != null) w.extGState('GS0');
    w.strokeColor(color);
    for (final q in quads) {
      final y = q.bottom + q.height * atHeight;
      w
        ..lineWidth((q.height * 0.06).clamp(0.5, 3.0))
        ..moveTo(q.left, y)
        ..lineTo(q.right, y)
        ..stroke();
    }
    _addAnnotation(
      pageIndex,
      _markupDict(subtype, rect, color, contents, author)
        ..['QuadPoints'] = _quadPoints(quads),
      _form(rect, w, resources: _resources(extGState: gs)),
    );
  }

  void _addShape(
    String subtype,
    int pageIndex,
    PdfRect rect,
    int? strokeColor,
    double strokeWidth,
    int? fillColor,
    double opacity,
    String? contents,
    String? author,
  ) {
    if (strokeColor == null && fillColor == null) {
      throw ArgumentError('strokeColor and fillColor are both null');
    }
    final stroking = strokeColor != null && strokeWidth > 0;
    final inset = stroking ? strokeWidth / 2 : 0.0;
    final w = ContentWriter();
    final gs = _alphaState(opacity);
    if (gs != null) w.extGState('GS0');
    if (fillColor != null) w.fillColor(fillColor);
    if (stroking) {
      w
        ..strokeColor(strokeColor)
        ..lineWidth(strokeWidth);
    }
    if (subtype == 'Square') {
      w.rect(rect.left + inset, rect.bottom + inset, rect.width - 2 * inset,
          rect.height - 2 * inset);
    } else {
      w.ellipse((rect.left + rect.right) / 2, (rect.bottom + rect.top) / 2,
          rect.width / 2 - inset, rect.height / 2 - inset);
    }
    if (fillColor != null && stroking) {
      w.fillAndStroke();
    } else if (fillColor != null) {
      w.fill();
    } else {
      w.stroke();
    }

    final dict =
        _markupDict(subtype, rect, strokeColor ?? fillColor!, contents, author)
          ..['BS'] = _borderStyle(stroking ? strokeWidth : 0);
    if (fillColor != null) {
      dict['IC'] = CosArray([
        for (final c in ContentWriter.rgbComponents(fillColor)) CosReal(c),
      ]);
    }
    _addAnnotation(pageIndex, dict,
        _form(rect, w, resources: _resources(extGState: gs)));
  }

  /// The common annotation dictionary: /C carries [color], /F sets Print
  /// so the annotation survives printing and flattening.
  CosDictionary _markupDict(String subtype, PdfRect rect, int color,
      String? contents, String? author) {
    final dict = CosDictionary({
      'Type': const CosName('Annot'),
      'Subtype': CosName(subtype),
      'Rect': _rectArray(rect),
      'F': const CosInteger(4),
      'C': CosArray([
        for (final c in ContentWriter.rgbComponents(color)) CosReal(c),
      ]),
    });
    if (contents != null) dict['Contents'] = CosString.fromText(contents);
    if (author != null) dict['T'] = CosString.fromText(author);
    return dict;
  }

  /// Wraps the annotation content in a Form XObject whose BBox is the
  /// annotation rect in page coordinates — the §12.5.5 algorithm then maps
  /// it onto /Rect as the identity.
  CosStream _form(PdfRect bbox, ContentWriter content,
      {CosDictionary? resources}) {
    final bytes = content.takeBytes();
    final dict = CosDictionary({
      'Type': const CosName('XObject'),
      'Subtype': const CosName('Form'),
      'BBox': _rectArray(bbox),
      'Length': CosInteger(bytes.length),
    });
    if (resources != null) dict['Resources'] = resources;
    return CosStream(dict, bytes);
  }

  /// Stages [annot] (with its appearance [form]) and links it into the
  /// page's /Annots array.
  void _addAnnotation(int pageIndex, CosDictionary annot, CosStream form) {
    annot['AP'] = CosDictionary({'N': _updater.addObject(form)});
    final page = document.page(pageIndex);
    final annotRef = _updater.addObject(annot);

    final raw = page.dict['Annots'];
    final resolved = document.cos.resolve(raw);
    if (resolved is CosArray) {
      resolved.items.add(annotRef);
      if (raw is CosReference) {
        _updater.replaceObject(raw.objectNumber, resolved);
      } else {
        _updater.markChanged(page.dict);
      }
    } else {
      page.dict['Annots'] = CosArray([annotRef]);
      _updater.markChanged(page.dict);
    }
  }

  CosDictionary? _alphaState(double opacity, {bool multiply = false}) {
    if (opacity >= 1 && !multiply) return null;
    final dict = CosDictionary({
      'Type': const CosName('ExtGState'),
      'CA': CosReal(opacity),
      'ca': CosReal(opacity),
    });
    if (multiply) dict['BM'] = const CosName('Multiply');
    return dict;
  }

  CosDictionary? _resources({CosDictionary? extGState, CosDictionary? font}) {
    if (extGState == null && font == null) return null;
    final dict = CosDictionary();
    if (extGState != null) {
      dict['ExtGState'] = CosDictionary({'GS0': extGState});
    }
    if (font != null) dict['Font'] = font;
    return dict;
  }

  /// A non-embedded base-14 Helvetica font with explicit /Widths, so both
  /// this renderer's substitution and other viewers space text correctly.
  CosDictionary _helvetica({bool bold = false, String name = 'Helv'}) =>
      CosDictionary({
        name: CosDictionary({
          'Type': const CosName('Font'),
          'Subtype': const CosName('Type1'),
          'BaseFont': CosName(bold ? 'Helvetica-Bold' : 'Helvetica'),
          'Encoding': const CosName('WinAnsiEncoding'),
          'FirstChar': const CosInteger(32),
          'LastChar': const CosInteger(126),
          'Widths': CosArray([
            for (final w in bold ? helveticaBoldWidths : helveticaWidths)
              CosInteger(w),
          ]),
        }),
      });

  CosDictionary _borderStyle(double width) => CosDictionary({
        'Type': const CosName('Border'),
        'W': CosReal(width),
        'S': const CosName('S'),
      });

  CosArray _rectArray(PdfRect rect) => CosArray([
        CosReal(rect.left),
        CosReal(rect.bottom),
        CosReal(rect.right),
        CosReal(rect.top),
      ]);

  /// QuadPoints in the order real-world writers use (upper-left,
  /// upper-right, lower-left, lower-right per quad).
  CosArray _quadPoints(List<PdfRect> quads) => CosArray([
        for (final q in quads) ...[
          CosReal(q.left), CosReal(q.top), //
          CosReal(q.right), CosReal(q.top),
          CosReal(q.left), CosReal(q.bottom),
          CosReal(q.right), CosReal(q.bottom),
        ],
      ]);

  PdfRect _boundsOf(List<PdfRect> quads) {
    if (quads.isEmpty) {
      throw ArgumentError.value(quads, 'quads', 'must be non-empty');
    }
    var rect = quads.first;
    for (final q in quads.skip(1)) {
      rect = PdfRect(
        rect.left < q.left ? rect.left : q.left,
        rect.bottom < q.bottom ? rect.bottom : q.bottom,
        rect.right > q.right ? rect.right : q.right,
        rect.top > q.top ? rect.top : q.top,
      );
    }
    return rect;
  }

  /// Greedy word wrap with Helvetica metrics; a single word longer than
  /// [maxWidth] overflows (and is clipped by the appearance).
  List<String> _wrap(String text, double fontSize, double maxWidth) {
    final lines = <String>[];
    for (final paragraph in text.split('\n')) {
      var line = '';
      for (final word in paragraph.split(' ')) {
        final candidate = line.isEmpty ? word : '$line $word';
        if (line.isNotEmpty &&
            measureHelvetica(candidate, fontSize) > maxWidth) {
          lines.add(line);
          line = word;
        } else {
          line = candidate;
        }
      }
      lines.add(line);
    }
    return lines;
  }
}
