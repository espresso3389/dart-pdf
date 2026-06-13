import 'dart:io';
import 'package:pdf_cos/pdf_cos.dart';
void main() {
  final raw = File('/tmp/Im3.jp2').readAsBytesSync();
  final sb = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    sb.write('${raw[i]}, ');
    if ((i + 1) % 20 == 0) sb.write('\n  ');
  }
  File('/tmp/im3_bytes.txt').writeAsStringSync(sb.toString());
  // decode and print a few pixels
  final img = JpxDecoder.decode(raw)!;
  final c = img.components, w = img.width;
  List<int> at(int x,int y)=>[for(var k=0;k<c;k++) img.samples[(y*w+x)*c+k]];
  print('${img.width}x${img.height} c=$c corner=${at(0,0)} mid=${at(w~/2,img.height~/2)}');
}
