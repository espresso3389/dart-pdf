import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

/// Reference values produced by littleCMS (via ImageMagick) for the same
/// profiles and inputs.
void expectSrgb(PdfColor color, List<int> want) {
  expect((color.red * 255).round(), closeTo(want[0], 3));
  expect((color.green * 255).round(), closeTo(want[1], 3));
  expect((color.blue * 255).round(), closeTo(want[2], 3));
}

void main() {
  test('v2 matrix/TRC RGB profiles (AdobeRGB1998) match littleCMS', () {
    final profile = IccProfile.parse(adobeRgb1998Icc())!;
    expect(profile.channels, 3);
    expectSrgb(
        profile.toSrgb([128 / 255, 64 / 255, 200 / 255]), [146, 62, 205]);
    expectSrgb(
        profile.toSrgb([200 / 255, 180 / 255, 30 / 255]), [209, 181, 0]);
    expectSrgb(
        profile.toSrgb([40 / 255, 150 / 255, 90 / 255]), [0, 151, 86]);
  });

  test('v4 parametric-curve RGB profiles (Display P3) match littleCMS', () {
    final profile = IccProfile.parse(displayP3Icc())!;
    expectSrgb(
        profile.toSrgb([128 / 255, 64 / 255, 200 / 255]), [138, 59, 207]);
    expectSrgb(
        profile.toSrgb([40 / 255, 150 / 255, 90 / 255]), [0, 153, 84]);
  });

  test('gray TRC profiles match littleCMS', () {
    final profile = IccProfile.parse(genericGrayIcc())!;
    expect(profile.channels, 1);
    expectSrgb(profile.toSrgb([64 / 255]), [81, 81, 81]);
    expectSrgb(profile.toSrgb([128 / 255]), [146, 146, 146]);
    expectSrgb(profile.toSrgb([192 / 255]), [203, 203, 203]);
  });

  test('LUT CMYK profiles with Lab PCS match littleCMS', () {
    final profile = IccProfile.parse(genericCmykIcc())!;
    expect(profile.channels, 4);
    expectSrgb(profile.toSrgb([1, 0, 0, 0]), [0, 164, 219]); // cyan
    expectSrgb(profile.toSrgb([0, 0, 0, 1]), [25, 26, 25]); // rich black
    expectSrgb(profile.toSrgb([50 / 255, 100 / 255, 150 / 255, 20 / 255]),
        [180, 142, 105]);
  });

  test('garbage parses to null, not an exception', () {
    expect(IccProfile.parse(ascii('not a profile at all')), isNull);
    final truncated = adobeRgb1998Icc().sublist(0, 200);
    expect(IccProfile.parse(truncated), isNull);
  });
}
