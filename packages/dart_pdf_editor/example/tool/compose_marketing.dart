// Turns raw device/window captures into App Store / Play Store marketing
// screenshots: each capture is dropped onto a brand gradient canvas with a
// headline and subtitle, framed with rounded corners and a soft shadow, and
// rendered at an exact store dimension.
//
// The whole composition is one SVG (gradient + text + the capture embedded as
// a base64 <image> with a rounded clip and a blurred drop shadow) rendered to
// PNG with `rsvg-convert -w <W> -h <H>` — no per-pixel work in Dart, crisp
// type from a real system font.
//
// Usage (tool/screenshots.sh drives this after each capture run):
//   dart run tool/compose_marketing.dart \
//     --in  doc/screenshots/<target>/<platform> \
//     --out doc/marketing/<target>/<platform> \
//     --orientation landscape|portrait \
//     --width 1440 --height 900 \
//     --target app|example
//
// Requires `rsvg-convert` on PATH (brew install librsvg).

import 'dart:convert';
import 'dart:io';

/// Headline + subtitle per screenshot, keyed `<target>/<basename>` (the raw
/// PNG name without its extension). Edit these freely — they're the only
/// marketing copy in the pipeline.
const _captions = <String, (String, String)>{
  // The standalone DartPDF app.
  'app/01-welcome': ('DartPDF', 'A fully native PDF editor'),
  'app/02-editor': ('Edit PDFs like a pro', 'Tabs, panels, and a full toolset'),
  'app/03-dark': ('Light or dark, your call', 'The whole app follows your theme'),

  // The dart_pdf_editor example showcase.
  'example/01-document': ('Open any PDF, instantly', 'Pure-Dart rendering on every platform'),
  'example/02-graphics': ('Pixel-perfect graphics', 'Gradients, shadings & transparency — native'),
  'example/03-annotations': ('Annotate with ease', 'Highlights, ink, notes, stamps & forms'),
  'example/04-markup': ('Powerful markup tools', 'Draw, shape, and sign right on the page'),
  'example/05-reader': ('A clean reading view', 'Distraction-free, with reflowable text'),
};

void main(List<String> argv) async {
  final args = _parseArgs(argv);
  final inDir = Directory(args['in']!);
  final outDir = Directory(args['out']!)..createSync(recursive: true);
  final orientation = args['orientation'] ?? 'landscape';
  final width = int.parse(args['width'] ?? (orientation == 'portrait' ? '1320' : '1440'));
  final height = int.parse(args['height'] ?? (orientation == 'portrait' ? '2868' : '900'));
  final target = args['target'] ?? inDir.parent.uri.pathSegments
      .where((s) => s.isNotEmpty)
      .last; // <target>/<platform>

  if (!inDir.existsSync()) {
    stderr.writeln('[compose] no input dir: ${inDir.path}');
    exit(1);
  }
  if (!await _has('rsvg-convert')) {
    stderr.writeln('[compose] rsvg-convert not found (brew install librsvg).');
    exit(1);
  }

  final shots = inDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.png'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (shots.isEmpty) {
    stderr.writeln('[compose] no PNGs in ${inDir.path}');
    exit(1);
  }

  var made = 0;
  for (final shot in shots) {
    final base = shot.uri.pathSegments.last.replaceAll('.png', '');
    final caption = _captions['$target/$base'] ?? (_titleCase(base), '');
    final svg = _composeSvg(
      shotBytes: shot.readAsBytesSync(),
      width: width,
      height: height,
      portrait: orientation == 'portrait',
      headline: caption.$1,
      subtitle: caption.$2,
    );
    final tmp = File('${outDir.path}/.$base.svg')..writeAsStringSync(svg);
    final out = '${outDir.path}/$base.png';
    final r = await Process.run('rsvg-convert', [
      '-w', '$width', '-h', '$height',
      '-o', out, tmp.path,
    ]);
    tmp.deleteSync();
    if (r.exitCode != 0) {
      stderr.writeln('[compose] $base failed: ${r.stderr}');
    } else {
      stdout.writeln('[compose] $out  (${width}x$height)');
      made++;
    }
  }
  stdout.writeln('[compose] $made marketing image(s) → ${outDir.path}/');
  if (made == 0) exit(1);
}

/// Builds the marketing SVG for one capture. The capture is scaled to fit a
/// content box (sized per orientation), centred horizontally, with a blurred
/// shadow behind it and a rounded clip in front; the headline/subtitle sit
/// above it.
String _composeSvg({
  required List<int> shotBytes,
  required int width,
  required int height,
  required bool portrait,
  required String headline,
  required String subtitle,
}) {
  final (sw, sh) = _pngSize(shotBytes);
  final b64 = base64Encode(shotBytes);
  final w = width.toDouble(), h = height.toDouble();

  // Type sizes scale with the canvas; portrait is narrower so it keys off
  // width, landscape off height.
  final unit = portrait ? w : h;
  final headSize = unit * (portrait ? 0.066 : 0.060);
  final subSize = unit * (portrait ? 0.040 : 0.034);
  final cornerRadius = (portrait ? w : h) * 0.028;

  // Text block near the top, then the capture fills the rest.
  final headY = h * (portrait ? 0.085 : 0.135);
  final subY = headY + headSize * 1.15;
  final contentTop = h * (portrait ? 0.20 : 0.28);
  final contentBottom = h * (portrait ? 0.97 : 0.93);
  // Side margins: portrait hugs the edges (a phone fills the width), landscape
  // leaves more air around the window.
  final sideMargin = w * (portrait ? 0.07 : 0.09);

  final boxW = w - sideMargin * 2;
  final boxH = contentBottom - contentTop;
  final scale = (boxW / sw).clamp(0.0, boxH / sh);
  final dw = sw * scale, dh = sh * scale;
  final dx = (w - dw) / 2;
  // Portrait anchors the device to the top of the content box (phone peeks off
  // the bottom edge); landscape centres the window in the box.
  final dy = portrait ? contentTop : contentTop + (boxH - dh) / 2;

  final shadowDy = h * 0.012;
  final blur = (portrait ? w : h) * 0.012;

  final head = _esc(headline);
  final sub = _esc(subtitle);

  return '''
<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height"
     viewBox="0 0 $width $height">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0"   stop-color="#0A1B3D"/>
      <stop offset="0.5" stop-color="#123E92"/>
      <stop offset="1"   stop-color="#1AA0E0"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.0" r="0.9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="shot">
      <rect x="$dx" y="$dy" width="$dw" height="$dh" rx="$cornerRadius" ry="$cornerRadius"/>
    </clipPath>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="$blur"/>
    </filter>
  </defs>

  <rect width="$width" height="$height" fill="url(#bg)"/>
  <rect width="$width" height="$height" fill="url(#glow)"/>

  <text x="${w / 2}" y="$headY" fill="#FFFFFF" text-anchor="middle"
        font-family="Helvetica Neue, Helvetica, Arial, sans-serif"
        font-weight="700" font-size="$headSize">$head</text>
  ${sub.isEmpty ? '' : '''
  <text x="${w / 2}" y="$subY" fill="#FFFFFF" fill-opacity="0.82" text-anchor="middle"
        font-family="Helvetica Neue, Helvetica, Arial, sans-serif"
        font-weight="400" font-size="$subSize">$sub</text>'''}

  <rect x="$dx" y="${dy + shadowDy}" width="$dw" height="$dh" rx="$cornerRadius" ry="$cornerRadius"
        fill="#000000" fill-opacity="0.38" filter="url(#soft)"/>
  <image x="$dx" y="$dy" width="$dw" height="$dh" clip-path="url(#shot)"
         preserveAspectRatio="none"
         xlink:href="data:image/png;base64,$b64"
         xmlns:xlink="http://www.w3.org/1999/xlink"/>
  <rect x="$dx" y="$dy" width="$dw" height="$dh" rx="$cornerRadius" ry="$cornerRadius"
        fill="none" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="2"/>
</svg>''';
}

/// Reads width/height from a PNG's IHDR (bytes 16–23, big-endian).
(int, int) _pngSize(List<int> b) {
  int u32(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  return (u32(16), u32(20));
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _titleCase(String name) => name
    .replaceAll(RegExp(r'^\d+-'), '')
    .split(RegExp(r'[-_]'))
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      final key = argv[i].substring(2);
      final val = (i + 1 < argv.length && !argv[i + 1].startsWith('--'))
          ? argv[++i]
          : 'true';
      out[key] = val;
    }
  }
  return out;
}

Future<bool> _has(String cmd) async {
  try {
    final r = await Process.run('command', ['-v', cmd], runInShell: true);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
