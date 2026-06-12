import 'dart:io';
import 'dart:ui' as ui;

class RenderGallery {
  RenderGallery(this.outDir) {
    outDir.createSync(recursive: true);
  }

  final Directory outDir;
  final _renders = <_Render>[];

  Future<void> add({
    required String pdfName,
    required int page,
    required ui.Image image,
  }) async {
    final pngName = '${_safeName(pdfName)}.p$page.png';
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${outDir.path}/$pngName').writeAsBytesSync(png!.buffer.asUint8List());
    _renders.add(_Render(
      pdfName: pdfName,
      page: page,
      pngName: pngName,
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
      ..writeln(
          '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px}')
      ..writeln(
          'figure{margin:0;padding:12px;background:white;border:1px solid #dadce0;border-radius:6px}')
      ..writeln(
          'img{display:block;max-width:100%;height:auto;background:white;border:1px solid #eee}')
      ..writeln(
          'figcaption{margin-top:8px;overflow-wrap:anywhere;color:#3c4043}')
      ..writeln('</style>')
      ..writeln('<h1>PDF corpus renders</h1>')
      ..writeln('<div class="grid">');
    for (final render in _renders) {
      html
        ..writeln('<figure>')
        ..writeln(
            '<a href="${_htmlAttr(render.pngName)}"><img src="${_htmlAttr(render.pngName)}" loading="lazy"></a>')
        ..writeln(
            '<figcaption>${_htmlText(render.pdfName)} page ${render.page + 1}<br>${render.width}x${render.height}</figcaption>')
        ..writeln('</figure>');
    }
    html
      ..writeln('</div>')
      ..writeln();
    File('${outDir.path}/index.html').writeAsStringSync(html.toString());
  }
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
    required this.pngName,
    required this.width,
    required this.height,
  });

  final String pdfName;
  final int page;
  final String pngName;
  final int width;
  final int height;
}
