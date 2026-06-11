part of 'editor.dart';

/// The drawn width of an ink segment at normalized [pressure] (0–1) for a
/// base [strokeWidth]: 0.4× when barely touching up to 1.6× at full
/// pressure, the base width at 0.5. Shared by [PdfAnnotationEditing.addInk]
/// appearances and live stroke previews so they look identical.
double pdfInkStrokeWidth(double strokeWidth, double pressure) =>
    strokeWidth * (0.4 + 1.2 * pressure.clamp(0.0, 1.0));

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
          resources:
              _resources(extGState: _alphaState(opacity, multiply: true))),
    );
  }

  /// Adds an underline beneath each quad in [quads].
  void addUnderline(int pageIndex, List<PdfRect> quads,
          {int color = 0x10A010,
          double opacity = 1,
          String? contents,
          String? author}) =>
      _addLineMarkup(
          'Underline', pageIndex, quads, color, opacity, contents, author,
          atHeight: 0.08);

  /// Adds a strike-out through each quad in [quads].
  void addStrikeOut(int pageIndex, List<PdfRect> quads,
          {int color = 0xD02020,
          double opacity = 1,
          String? contents,
          String? author}) =>
      _addLineMarkup(
          'StrikeOut', pageIndex, quads, color, opacity, contents, author,
          atHeight: 0.45);

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
  ///
  /// [pressures] optionally gives one normalized pressure (0–1) per point
  /// of the corresponding stroke (a null entry leaves that stroke at the
  /// uniform [strokeWidth]). Pressured strokes render with a varying
  /// width — [pdfInkStrokeWidth] per segment — the natural look for
  /// stylus (Apple Pencil) drawings. The /InkList always stores the
  /// centerline points; the variable width lives in the appearance
  /// stream, which conforming viewers prefer.
  void addInk(
    int pageIndex,
    List<List<(double, double)>> strokes, {
    int color = 0xD02020,
    double strokeWidth = 2,
    double opacity = 1,
    List<List<double>?>? pressures,
    String? contents,
    String? author,
  }) {
    if (strokes.isEmpty || strokes.any((s) => s.isEmpty)) {
      throw ArgumentError.value(strokes, 'strokes', 'must be non-empty');
    }
    if (pressures != null &&
        (pressures.length != strokes.length ||
            [
              for (var i = 0; i < strokes.length; i++)
                if (pressures[i] != null &&
                    pressures[i]!.length != strokes[i].length)
                  i
            ].isNotEmpty)) {
      throw ArgumentError.value(
          pressures, 'pressures', 'must parallel strokes point for point');
    }
    var maxWidth = strokeWidth;
    if (pressures != null) {
      for (final list in pressures) {
        for (final p in list ?? const <double>[]) {
          final width = pdfInkStrokeWidth(strokeWidth, p);
          if (width > maxWidth) maxWidth = width;
        }
      }
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
    final pad = maxWidth / 2 + 1;
    final rect = PdfRect(minX - pad, minY - pad, maxX + pad, maxY + pad);

    final w = ContentWriter();
    final gs = _alphaState(opacity);
    if (gs != null) w.extGState('GS0');
    w
      ..strokeColor(color)
      ..lineWidth(strokeWidth)
      ..roundLines();
    for (var s = 0; s < strokes.length; s++) {
      final stroke = strokes[s];
      final pressure = pressures?[s];
      final (x0, y0) = stroke.first;
      if (pressure == null) {
        w.moveTo(x0, y0);
        if (stroke.length == 1) {
          // a dot: zero-length segment with round caps paints a circle
          w.lineTo(x0, y0);
        }
        for (final (x, y) in stroke.skip(1)) {
          w.lineTo(x, y);
        }
        w.stroke();
        continue;
      }
      if (stroke.length == 1) {
        w
          ..lineWidth(pdfInkStrokeWidth(strokeWidth, pressure.first))
          ..moveTo(x0, y0)
          ..lineTo(x0, y0)
          ..stroke();
        continue;
      }
      // one stroked segment per point pair, each at its own width; the
      // round caps and joins hide the seams
      for (var i = 0; i < stroke.length - 1; i++) {
        final (xa, ya) = stroke[i];
        final (xb, yb) = stroke[i + 1];
        w
          ..lineWidth(pdfInkStrokeWidth(
              strokeWidth, (pressure[i] + pressure[i + 1]) / 2))
          ..moveTo(xa, ya)
          ..lineTo(xb, yb)
          ..stroke();
      }
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
      _addShape('Square', pageIndex, rect, strokeColor, strokeWidth, fillColor,
          opacity, contents, author);

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
      _addShape('Circle', pageIndex, rect, strokeColor, strokeWidth, fillColor,
          opacity, contents, author);

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

    final da =
        '${ContentWriter.rgbComponents(color).map(ContentWriter.fmt).join(' ')} rg '
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
              extGState: gs, font: _helvetica(bold: true, name: 'HelvB'))),
    );
  }

  /// Removes [annotation] from the page, along with its popup, if any.
  void removeAnnotation(int pageIndex, PdfAnnotation annotation) {
    final cos = document.cos;
    final page = document.page(pageIndex);
    final raw = page.dict['Annots'];
    final array = cos.resolve(raw);
    if (array is! CosArray) return;
    final popup = cos.resolve(annotation.dict['Popup']);
    final before = array.items.length;
    array.items.removeWhere((item) {
      final resolved = cos.resolve(item);
      return identical(resolved, annotation.dict) ||
          (popup is CosDictionary && identical(resolved, popup));
    });
    if (array.items.length == before) return;
    if (raw is CosReference) {
      _updater.replaceObject(raw.objectNumber, array);
    } else {
      _updater.markChanged(page.dict);
    }
  }

  /// Translates [annotation] by ([dx], [dy]) in page space.
  ///
  /// Shifts /Rect and the absolute-coordinate entries that travel with it
  /// (/QuadPoints, /InkList, /L, /Vertices, /CL). The appearance stream
  /// needs no rewrite: viewers map its BBox onto the new /Rect (§12.5.5).
  void moveAnnotation(
      int pageIndex, PdfAnnotation annotation, double dx, double dy) {
    final dict = annotation.dict;
    final rect = annotation.rect;
    dict['Rect'] = _rectArray(PdfRect(
      rect.left + dx,
      rect.bottom + dy,
      rect.right + dx,
      rect.top + dy,
    ));
    for (final key in const ['QuadPoints', 'L', 'Vertices', 'CL']) {
      final shifted = _shiftPoints(dict[key], dx, dy);
      if (shifted != null) dict[key] = shifted;
    }
    final ink = document.cos.resolve(dict['InkList']);
    if (ink is CosArray) {
      dict['InkList'] = CosArray([
        for (final stroke in ink.items) _shiftPoints(stroke, dx, dy) ?? stroke,
      ]);
    }
    _markAnnotationChanged(pageIndex, dict);
  }

  /// Resizes [annotation] so its /Rect becomes [to].
  ///
  /// The absolute-coordinate entries that travel with the rect
  /// (/QuadPoints, /InkList, /L, /Vertices, /CL) are mapped through the
  /// old-rect → new-rect affine, so the annotation's geometry stays
  /// consistent for viewers that regenerate appearances. The appearance
  /// stream itself needs no rewrite: viewers fit its BBox onto the new
  /// /Rect (§12.5.5), stretching the existing artwork.
  void resizeAnnotation(int pageIndex, PdfAnnotation annotation, PdfRect to) {
    final from = annotation.rect;
    if (from.width <= 0 ||
        from.height <= 0 ||
        to.width <= 0 ||
        to.height <= 0) {
      throw ArgumentError('resizeAnnotation needs non-degenerate rects');
    }
    final dict = annotation.dict;
    dict['Rect'] = _rectArray(to);
    final sx = to.width / from.width;
    final sy = to.height / from.height;
    double mapX(double x) => to.left + (x - from.left) * sx;
    double mapY(double y) => to.bottom + (y - from.bottom) * sy;
    for (final key in const ['QuadPoints', 'L', 'Vertices', 'CL']) {
      final scaled = _mapPoints(dict[key], mapX, mapY);
      if (scaled != null) dict[key] = scaled;
    }
    final ink = document.cos.resolve(dict['InkList']);
    if (ink is CosArray) {
      dict['InkList'] = CosArray([
        for (final stroke in ink.items)
          _mapPoints(stroke, mapX, mapY) ?? stroke,
      ]);
    }
    _markAnnotationChanged(pageIndex, dict);
  }

  /// Rotates [annotation] by [degrees] counterclockwise about the center
  /// of its /Rect.
  ///
  /// The rotation is folded into the appearance stream's /Matrix — with
  /// the current BBox→Rect fit baked in first, so artwork whose BBox
  /// aspect differs from /Rect rotates without shearing — and /Rect
  /// becomes the bounding box of the rotated annotation, same center.
  /// Every viewer that implements the §12.5.5 fit then renders the
  /// artwork rotated. The absolute-coordinate entries that travel with
  /// the rect (/QuadPoints, /InkList, /L, /Vertices, /CL) rotate too, so
  /// viewers that regenerate appearances stay consistent.
  void rotateAnnotation(
      int pageIndex, PdfAnnotation annotation, double degrees) {
    final form = annotation.normalAppearance;
    if (form == null) {
      throw StateError('rotateAnnotation needs an appearance stream');
    }
    final rect = annotation.rect;
    if (rect.width <= 0 || rect.height <= 0) {
      throw ArgumentError('rotateAnnotation needs a non-degenerate rect');
    }
    final cos = document.cos;
    final bbox = pdfRectFrom(cos, form.dictionary['BBox']);
    if (bbox == null) return; // no BBox: §12.5.5 has nothing to map

    // the current BBox→Rect fit (the same bounds walk as the renderer)
    final m = _formMatrix(form);
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final (x, y) in [
      (bbox.left, bbox.bottom),
      (bbox.right, bbox.bottom),
      (bbox.right, bbox.top),
      (bbox.left, bbox.top),
    ]) {
      final tx = m[0] * x + m[2] * y + m[4];
      final ty = m[1] * x + m[3] * y + m[5];
      minX = math.min(minX, tx);
      maxX = math.max(maxX, tx);
      minY = math.min(minY, ty);
      maxY = math.max(maxY, ty);
    }
    if (maxX - minX < 1e-9 || maxY - minY < 1e-9) return;
    final sx = rect.width / (maxX - minX);
    final sy = rect.height / (maxY - minY);
    final fit = [sx, 0.0, 0.0, sy, rect.left - minX * sx,
        rect.bottom - minY * sy];

    final theta = degrees * math.pi / 180;
    final cosT = math.cos(theta), sinT = math.sin(theta);
    final cx = (rect.left + rect.right) / 2;
    final cy = (rect.bottom + rect.top) / 2;
    final rotation = [
      cosT, sinT, -sinT, cosT,
      cx - (cx * cosT - cy * sinT),
      cy - (cx * sinT + cy * cosT),
    ];
    final matrix = _mulAffine(_mulAffine(m, fit), rotation);
    form.dictionary['Matrix'] =
        CosArray([for (final v in matrix) CosReal(v)]);

    // /Rect: the BBox corners' bounds under the new matrix. The matrix
    // carries the whole rotation history, so this stays the tightest box
    // around the rotated artwork — two 45° turns land exactly where one
    // 90° turn does, instead of compounding loose bounding boxes.
    var newMinX = double.infinity, newMinY = double.infinity;
    var newMaxX = double.negativeInfinity, newMaxY = double.negativeInfinity;
    for (final (x, y) in [
      (bbox.left, bbox.bottom),
      (bbox.right, bbox.bottom),
      (bbox.right, bbox.top),
      (bbox.left, bbox.top),
    ]) {
      final tx = matrix[0] * x + matrix[2] * y + matrix[4];
      final ty = matrix[1] * x + matrix[3] * y + matrix[5];
      newMinX = math.min(newMinX, tx);
      newMaxX = math.max(newMaxX, tx);
      newMinY = math.min(newMinY, ty);
      newMaxY = math.max(newMaxY, ty);
    }
    annotation.dict['Rect'] =
        _rectArray(PdfRect(newMinX, newMinY, newMaxX, newMaxY));

    (double, double) rotate(double x, double y) => (
          cx + (x - cx) * cosT - (y - cy) * sinT,
          cy + (x - cx) * sinT + (y - cy) * cosT,
        );
    for (final key in const ['QuadPoints', 'L', 'Vertices', 'CL']) {
      final rotated = _mapPointPairs(annotation.dict[key], rotate);
      if (rotated != null) annotation.dict[key] = rotated;
    }
    final ink = cos.resolve(annotation.dict['InkList']);
    if (ink is CosArray) {
      annotation.dict['InkList'] = CosArray([
        for (final stroke in ink.items)
          _mapPointPairs(stroke, rotate) ?? stroke,
      ]);
    }

    final formRef = cos.referenceTo(form);
    if (formRef != null) _updater.replaceObject(formRef.objectNumber, form);
    _markAnnotationChanged(pageIndex, annotation.dict);
  }

  /// `first`, then `second` — the affine product in PDF's row-vector
  /// convention, both as `[a b c d e f]`.
  static List<double> _mulAffine(List<double> first, List<double> second) => [
        first[0] * second[0] + first[1] * second[2],
        first[0] * second[1] + first[1] * second[3],
        first[2] * second[0] + first[3] * second[2],
        first[2] * second[1] + first[3] * second[3],
        first[4] * second[0] + first[5] * second[2] + second[4],
        first[4] * second[1] + first[5] * second[3] + second[5],
      ];

  /// An x y x y ... array translated by (dx, dy), or null if [raw] is not
  /// a numeric array.
  CosArray? _shiftPoints(CosObject? raw, double dx, double dy) =>
      _mapPoints(raw, (x) => x + dx, (y) => y + dy);

  /// An x y x y ... array with each coordinate mapped, or null if [raw]
  /// is not a numeric array.
  CosArray? _mapPoints(CosObject? raw, double Function(double) mapX,
          double Function(double) mapY) =>
      _mapPointPairs(raw, (x, y) => (mapX(x), mapY(y)));

  /// An x y x y ... array with each point mapped jointly (rotation needs
  /// both coordinates), or null if [raw] is not a numeric array.
  CosArray? _mapPointPairs(
      CosObject? raw, (double, double) Function(double x, double y) map) {
    final cos = document.cos;
    final array = cos.resolve(raw);
    if (array is! CosArray) return null;
    final values = <double>[];
    for (var i = 0; i < array.length; i++) {
      final n = cos.resolve(array[i]);
      if (n is CosInteger) {
        values.add(n.value.toDouble());
      } else if (n is CosReal) {
        values.add(n.value);
      } else {
        return null;
      }
    }
    final mapped = <CosObject>[];
    for (var i = 0; i + 1 < values.length; i += 2) {
      final (x, y) = map(values[i], values[i + 1]);
      mapped
        ..add(CosReal(x))
        ..add(CosReal(y));
    }
    return CosArray(mapped);
  }

  /// Stages whatever object owns [dict]'s bytes: the annotation itself
  /// when indirect, otherwise its containing /Annots array or page.
  void _markAnnotationChanged(int pageIndex, CosDictionary dict) {
    final cos = document.cos;
    final ref = cos.referenceTo(dict);
    if (ref != null) {
      _updater.replaceObject(ref.objectNumber, dict);
      return;
    }
    final page = document.page(pageIndex);
    final raw = page.dict['Annots'];
    final array = cos.resolve(raw);
    if (raw is CosReference && array is CosArray) {
      _updater.replaceObject(raw.objectNumber, array);
    } else {
      _updater.markChanged(page.dict);
    }
  }

  /// Bakes the page's annotation appearances into its content streams and
  /// removes those annotations, making them permanent, non-interactive
  /// page graphics.
  ///
  /// Annotations without a paintable appearance — hidden or no-view ones,
  /// popups, and any without /AP — are left in place untouched.
  void flattenAnnotations(int pageIndex) {
    final cos = document.cos;
    final page = document.page(pageIndex);

    // copy-on-write resources: the page's dict may be shared between
    // pages (inherited), so additions go into clones
    final ownResources = cos.resolve(page.dict['Resources']);
    final resources = CosDictionary({
      ...(ownResources is CosDictionary ? ownResources : page.resources)
          .entries,
    });
    final existingXObjects = cos.resolve(resources['XObject']);
    final xObjects = CosDictionary({
      if (existingXObjects is CosDictionary) ...existingXObjects.entries,
    });

    final w = ContentWriter()
      // restore the state the prefix stream saved before the original
      // content ran, so annotations paint over a clean slate
      ..restore();
    final flattened = <CosDictionary>{};
    var index = 0;
    for (final annot in page.annotations) {
      if (annot.isHidden || annot.isNoView || annot.subtype == 'Popup') {
        continue;
      }
      final form = annot.normalAppearance;
      if (form == null) continue;
      final rect = annot.rect;
      final bbox = pdfRectFrom(cos, form.dictionary['BBox']);
      if (bbox == null || rect.width <= 0 || rect.height <= 0) continue;

      // §12.5.5 algorithm: transform the BBox corners by the form /Matrix,
      // then scale/translate the resulting bounds onto /Rect. The /Matrix
      // itself is applied by the Do operator, so only the fit goes in cm.
      final m = _formMatrix(form);
      var minX = double.infinity, minY = double.infinity;
      var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
      for (final (x, y) in [
        (bbox.left, bbox.bottom),
        (bbox.right, bbox.bottom),
        (bbox.right, bbox.top),
        (bbox.left, bbox.top),
      ]) {
        final tx = m[0] * x + m[2] * y + m[4];
        final ty = m[1] * x + m[3] * y + m[5];
        if (tx < minX) minX = tx;
        if (tx > maxX) maxX = tx;
        if (ty < minY) minY = ty;
        if (ty > maxY) maxY = ty;
      }
      final sx = maxX - minX > 1e-9 ? rect.width / (maxX - minX) : 1.0;
      final sy = maxY - minY > 1e-9 ? rect.height / (maxY - minY) : 1.0;

      var name = 'FlatAnnot$index';
      while (xObjects.containsKey(name)) {
        name = 'FlatAnnot${++index}';
      }
      index++;
      xObjects[name] = cos.referenceTo(form) ?? _updater.addObject(form);
      w
        ..save()
        ..concatMatrix(
            sx, 0, 0, sy, rect.left - minX * sx, rect.bottom - minY * sy)
        ..drawXObject(name)
        ..restore();
      flattened.add(annot.dict);
    }
    if (flattened.isEmpty) return;

    resources['XObject'] = xObjects;
    page.dict['Resources'] = resources;

    // sandwich the original content between q and Q so its leftover
    // graphics state cannot leak into the appearance drawing
    final rawContents = page.dict['Contents'];
    final resolvedContents = cos.resolve(rawContents);
    final items = <CosObject>[_updater.addObject(_rawStream('q\n'))];
    if (resolvedContents is CosArray) {
      items.addAll(resolvedContents.items);
    } else if (resolvedContents is CosStream) {
      items.add(rawContents is CosReference
          ? rawContents
          : _updater.addObject(resolvedContents));
    }
    final suffix = w.takeBytes();
    items.add(_updater.addObject(CosStream(
        CosDictionary({'Length': CosInteger(suffix.length)}), suffix)));
    page.dict['Contents'] = CosArray(items);

    final annotsArray = cos.resolve(page.dict['Annots']);
    if (annotsArray is CosArray) {
      final remaining = [
        for (final item in annotsArray.items)
          if (!flattened.contains(cos.resolve(item))) item,
      ];
      if (remaining.isEmpty) {
        page.dict.entries.remove('Annots');
      } else {
        page.dict['Annots'] = CosArray(remaining);
      }
    }
    _updater.markChanged(page.dict);
  }

  // ---------------------------------------------------------------------
  // shared machinery

  List<double> _formMatrix(CosStream form) {
    final raw = document.cos.resolve(form.dictionary['Matrix']);
    if (raw is CosArray && raw.length >= 6) {
      final values = <double>[];
      for (var i = 0; i < 6; i++) {
        final n = document.cos.resolve(raw[i]);
        values.add(n is CosInteger
            ? n.value.toDouble()
            : n is CosReal
                ? n.value
                : (i == 0 || i == 3 ? 1.0 : 0.0));
      }
      return values;
    }
    return const [1, 0, 0, 1, 0, 0];
  }

  CosStream _rawStream(String text) {
    final bytes = Uint8List.fromList(text.codeUnits);
    return CosStream(
        CosDictionary({'Length': CosInteger(bytes.length)}), bytes);
  }

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
    _addAnnotation(
        pageIndex, dict, _form(rect, w, resources: _resources(extGState: gs)));
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
