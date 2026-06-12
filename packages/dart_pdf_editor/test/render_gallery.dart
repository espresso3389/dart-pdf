import 'dart:io';
import 'dart:ui' as ui;

class RenderGallery {
  RenderGallery(this.outDir) {
    outDir.createSync(recursive: true);
    _writeIndex();
  }

  final Directory outDir;
  final _renders = <_Render>[];

  File get indexFile => File('${outDir.path}/index.html');

  Future<void> add({
    required String pdfName,
    required int page,
    required ui.Image image,
    File? baseline,
    ui.Image? diff,
    double? differenceFraction,
  }) async {
    final baseName = '${_safeName(pdfName)}.p$page';
    final actualName = '$baseName.dart.png';
    final actualPng = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${outDir.path}/$actualName')
        .writeAsBytesSync(actualPng!.buffer.asUint8List());

    String? baselineName;
    if (baseline != null && baseline.existsSync()) {
      baselineName = '$baseName.baseline.png';
      baseline.copySync('${outDir.path}/$baselineName');
    }

    String? diffName;
    if (diff != null) {
      diffName = '$baseName.diff.png';
      final diffPng = await diff.toByteData(format: ui.ImageByteFormat.png);
      File('${outDir.path}/$diffName')
          .writeAsBytesSync(diffPng!.buffer.asUint8List());
    }

    _renders.add(_Render(
      pdfName: pdfName,
      page: page,
      actualName: actualName,
      baselineName: baselineName,
      diffName: diffName,
      differenceFraction: differenceFraction,
      width: image.width,
      height: image.height,
    ));
    _writeIndex();
  }

  void _writeIndex() {
    final html = StringBuffer()
      ..writeln('<!doctype html>')
      ..writeln('<meta charset="utf-8">')
      ..writeln('<title>PDF corpus renders</title>')
      ..writeln('<style>')
      ..writeln(
          'body{font:14px system-ui,sans-serif;margin:24px;background:#f6f7f8;color:#202124}')
      ..writeln('h1{font-size:20px;margin:0 0 16px}')
      ..writeln('.results{display:flex;flex-direction:column;gap:16px}')
      ..writeln(
          '.result{margin:0;padding:12px;background:white;border:1px solid #dadce0;border-radius:6px}')
      ..writeln('.meta{margin:0 0 10px;overflow-wrap:anywhere;color:#3c4043}')
      ..writeln(
          '.shots{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;align-items:start}')
      ..writeln('.shot-label{font-size:12px;color:#5f6368;margin:0 0 6px}')
      ..writeln(
          'img{display:block;max-width:100%;height:auto;background:white;border:1px solid #eee}')
      ..writeln(
          '.missing{border:1px dashed #dadce0;color:#80868b;padding:32px 8px;text-align:center;background:#fafafa}')
      ..writeln('@media (max-width: 900px){.shots{grid-template-columns:1fr}}')
      ..writeln('</style>')
      ..writeln('<h1>PDF corpus renders</h1>')
      ..writeln('<div class="results">');
    for (final render in _renders) {
      html
        ..writeln('<figure class="result">')
        ..writeln(
            '<figcaption class="meta">${_htmlText(render.pdfName)} page ${render.page + 1}<br>${render.width}x${render.height}${_difference(render.differenceFraction)}</figcaption>')
        ..writeln('<div class="shots">')
        ..writeln(_shot('PDF.js baseline', render.baselineName))
        ..writeln(_shot('Dart render', render.actualName))
        ..writeln(_shot('Diff', render.diffName))
        ..writeln('</div>')
        ..writeln('</figure>');
    }
    html
      ..writeln('</div>')
      ..writeln();
    indexFile.writeAsStringSync(html.toString());
  }
}

String _shot(String label, String? fileName) {
  if (fileName == null) {
    return '<div><div class="shot-label">$label</div><div class="missing">missing</div></div>';
  }
  final escaped = _htmlAttr(fileName);
  return '<div><div class="shot-label">$label</div><a href="$escaped"><img src="$escaped" loading="lazy"></a></div>';
}

String _difference(double? fraction) {
  if (fraction == null) return '';
  return '<br>${(fraction * 100).toStringAsFixed(3)}% differing pixels';
}

String _safeName(String name) =>
    name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

String _htmlText(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _htmlAttr(String text) => _htmlText(text).replaceAll('"', '&quot;');

class _Render {
  const _Render({
    required this.pdfName,
    required this.page,
    required this.actualName,
    required this.baselineName,
    required this.diffName,
    required this.differenceFraction,
    required this.width,
    required this.height,
  });

  final String pdfName;
  final int page;
  final String actualName;
  final String? baselineName;
  final String? diffName;
  final double? differenceFraction;
  final int width;
  final int height;
}
