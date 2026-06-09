import 'package:pdf_cos/pdf_cos.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

CosObject parse(String source) => CosParser(ascii(source)).parseObject();

void main() {
  test('scalars', () {
    expect(parse('true'), const CosBoolean(true));
    expect(parse('false'), const CosBoolean(false));
    expect(parse('null'), CosNull.instance);
    expect(parse('42'), const CosInteger(42));
    expect(parse('3.5'), const CosReal(3.5));
    expect(parse('/Name'), const CosName('Name'));
    expect(parse('(text)'), CosString.fromText('text'));
  });

  test('references need the full N G R pattern', () {
    expect(parse('12 0 R'), const CosReference(12, 0));
    expect(parse('12'), const CosInteger(12));
    expect((parse('[1 2 R]') as CosArray).items, [const CosReference(1, 2)]);
    // bare integers next to each other stay integers
    expect((parse('[1 2 3]') as CosArray).items,
        [const CosInteger(1), const CosInteger(2), const CosInteger(3)]);
  });

  test('arrays, nested', () {
    final array = parse('[1 [2 3] /N (s) 4 0 R]') as CosArray;
    expect(array.length, 5);
    expect((array[1] as CosArray).items, [const CosInteger(2), const CosInteger(3)]);
    expect(array[4], const CosReference(4, 0));
  });

  test('dictionaries, nested', () {
    final dict = parse(
            '<< /Type /Page /Parent 2 0 R /Box [0 0 612 792] /Inner << /A 1 >> >>')
        as CosDictionary;
    expect(dict.typeName, 'Page');
    expect(dict['Parent'], const CosReference(2, 0));
    expect((dict['Box'] as CosArray).length, 4);
    expect((dict['Inner'] as CosDictionary)['A'], const CosInteger(1));
  });

  test('indirect object', () {
    final obj = CosParser(ascii('7 0 obj << /A 1 >> endobj'))
        .parseIndirectObject();
    expect(obj.objectNumber, 7);
    expect(obj.generation, 0);
    expect((obj.object as CosDictionary)['A'], const CosInteger(1));
  });

  test('missing endobj is tolerated', () {
    final obj = CosParser(ascii('7 0 obj 42 8 0 obj')).parseIndirectObject();
    expect(obj.object, const CosInteger(42));
  });

  group('streams', () {
    test('direct /Length', () {
      final stream =
          parse('<< /Length 5 >>\nstream\nHello\nendstream') as CosStream;
      expect(String.fromCharCodes(stream.rawBytes), 'Hello');
    });

    test('wrong /Length falls back to scanning', () {
      final stream =
          parse('<< /Length 999 >>\nstream\nHello\nendstream') as CosStream;
      expect(String.fromCharCodes(stream.rawBytes), 'Hello');
    });

    test('indirect /Length uses the resolver', () {
      final parser = CosParser(
        ascii('<< /Length 9 0 R >>\nstream\nHello\nendstream'),
        resolver: (ref) =>
            ref == const CosReference(9, 0) ? const CosInteger(5) : CosNull.instance,
      );
      final stream = parser.parseObject() as CosStream;
      expect(String.fromCharCodes(stream.rawBytes), 'Hello');
    });

    test('binary payload containing parens survives', () {
      final stream = parse('<< /Length 3 >>\nstream\n)((\nendstream')
          as CosStream;
      expect(String.fromCharCodes(stream.rawBytes), ')((');
    });
  });
}
