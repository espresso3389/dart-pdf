import 'dart:ui';

import 'package:pdf_document/pdf_document.dart';

/// Converts between a page's PDF user space (origin bottom-left, y up,
/// points) and the view space of the widget displaying it (origin
/// top-left, y down, logical pixels).
///
/// Handed to [PdfViewer.pageOverlayBuilder] so apps can pin Flutter
/// widgets to positions on the page; the inverse mappings support
/// hit-testing and authoring (e.g. placing an annotation where the user
/// tapped).
class PdfPageGeometry {
  const PdfPageGeometry({
    required this.cropBox,
    required this.rotation,
    required this.viewSize,
  });

  /// The page's crop box — the region the view displays.
  final PdfRect cropBox;

  /// The page's /Rotate value (0, 90, 180, or 270).
  // TODO: fold rotation into the mappings; sideways pages currently get
  // the unrotated transform (same gap as selection and highlights).
  final int rotation;

  /// The size the page occupies on screen, in logical pixels.
  final Size viewSize;

  /// Logical pixels per PDF point.
  double get scale => cropBox.width <= 0 ? 1 : viewSize.width / cropBox.width;

  Offset toViewOffset(double x, double y) =>
      Offset((x - cropBox.left) * scale, (cropBox.top - y) * scale);

  Rect toViewRect(PdfRect rect) => Rect.fromLTRB(
        (rect.left - cropBox.left) * scale,
        (cropBox.top - rect.top) * scale,
        (rect.right - cropBox.left) * scale,
        (cropBox.top - rect.bottom) * scale,
      );

  /// View position → (x, y) in page space.
  (double, double) toPagePoint(Offset offset) => (
        cropBox.left + offset.dx / scale,
        cropBox.top - offset.dy / scale,
      );

  PdfRect toPageRect(Rect rect) => PdfRect(
        cropBox.left + rect.left / scale,
        cropBox.top - rect.bottom / scale,
        cropBox.left + rect.right / scale,
        cropBox.top - rect.top / scale,
      );
}
