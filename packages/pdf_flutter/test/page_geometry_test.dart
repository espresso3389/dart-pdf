import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';

void main() {
  // US Letter shown 800px wide; crop box offset exercises the origin shift
  const geometry = PdfPageGeometry(
    cropBox: PdfRect(10, 20, 622, 812),
    rotation: 0,
    viewSize: Size(800, 1035.3),
  );

  test('maps PDF space to view space', () {
    final scale = 800 / 612;
    expect(geometry.scale, moreOrLessEquals(scale));
    // bottom-left of the crop box is the view's bottom-left corner
    final origin = geometry.toViewOffset(10, 20);
    expect(origin.dx, moreOrLessEquals(0));
    expect(origin.dy, moreOrLessEquals(792 * scale));
    // top-left corner of the page is the view origin
    final topLeft = geometry.toViewOffset(10, 812);
    expect(topLeft.dx, moreOrLessEquals(0));
    expect(topLeft.dy, moreOrLessEquals(0));

    final rect = geometry.toViewRect(const PdfRect(82, 712, 182, 762));
    expect(rect.left, moreOrLessEquals(72 * scale));
    expect(rect.top, moreOrLessEquals((812 - 762) * scale));
    expect(rect.width, moreOrLessEquals(100 * scale));
    expect(rect.height, moreOrLessEquals(50 * scale));
  });

  test('round-trips between page and view space', () {
    const pageRect = PdfRect(82, 712, 182, 762);
    final back = geometry.toPageRect(geometry.toViewRect(pageRect));
    expect(back.left, moreOrLessEquals(pageRect.left));
    expect(back.bottom, moreOrLessEquals(pageRect.bottom));
    expect(back.right, moreOrLessEquals(pageRect.right));
    expect(back.top, moreOrLessEquals(pageRect.top));

    final (x, y) = geometry.toPagePoint(geometry.toViewOffset(123, 456));
    expect(x, moreOrLessEquals(123));
    expect(y, moreOrLessEquals(456));
  });
}
