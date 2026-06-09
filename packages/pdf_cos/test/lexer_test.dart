import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:test/test.dart';

CosToken lex(String source) => CosLexer(ascii(source)).nextToken();

List<CosToken> lexAll(String source) {
  final lexer = CosLexer(ascii(source));
  final tokens = <CosToken>[];
  while (true) {
    final t = lexer.nextToken();
    if (t.type == CosTokenType.eof) break;
    tokens.add(t);
  }
  return tokens;
}

void main() {
  group('numbers', () {
    test('integers', () {
      expect(lex('42').intValue, 42);
      expect(lex('-17').intValue, -17);
      expect(lex('+17').intValue, 17);
      expect(lex('0000000017').intValue, 17);
    });

    test('reals', () {
      expect(lex('3.14').realValue, 3.14);
      expect(lex('-0.5').realValue, -0.5);
      expect(lex('.5').realValue, 0.5);
      expect(lex('-.5').realValue, -0.5);
      expect(lex('4.').realValue, 4.0);
    });
  });

  group('names', () {
    test('simple', () {
      expect(lex('/Type').textValue, 'Type');
    });

    test('hex escapes', () {
      expect(lex('/A#42').textValue, 'AB');
      expect(lex('/Lime#20Green').textValue, 'Lime Green');
    });

    test('terminated by delimiter', () {
      final tokens = lexAll('/Name/Other');
      expect(tokens, hasLength(2));
      expect(tokens[0].textValue, 'Name');
      expect(tokens[1].textValue, 'Other');
    });
  });

  group('literal strings', () {
    test('plain', () {
      expect(String.fromCharCodes(lex('(Hello)').bytesValue), 'Hello');
    });

    test('nested parentheses', () {
      expect(String.fromCharCodes(lex('(a (b) c)').bytesValue), 'a (b) c');
    });

    test('escapes', () {
      expect(String.fromCharCodes(lex(r'(a\(b\)c\\d)').bytesValue),
          r'a(b)c\d');
      expect(lex(r'(\n\r\t)').bytesValue, [0x0A, 0x0D, 0x09]);
    });

    test('octal escapes', () {
      expect(lex(r'(\053)').bytesValue, [0x2B]);
      expect(lex(r'(\53)').bytesValue, [0x2B]);
    });

    test('line continuation', () {
      expect(String.fromCharCodes(lex('(ab\\\ncd)').bytesValue), 'abcd');
    });

    test('embedded CRLF normalizes to LF', () {
      expect(lex('(a\r\nb)').bytesValue, [0x61, 0x0A, 0x62]);
    });
  });

  group('hex strings', () {
    test('plain', () {
      expect(String.fromCharCodes(lex('<48656C6C6F>').bytesValue), 'Hello');
    });

    test('whitespace ignored, odd digit padded', () {
      expect(lex('<90 1F A>').bytesValue, [0x90, 0x1F, 0xA0]);
    });
  });

  test('structural tokens and keywords', () {
    final tokens = lexAll('<< /K [1 2] >> stream true R');
    expect(tokens.map((t) => t.type), [
      CosTokenType.dictOpen,
      CosTokenType.name,
      CosTokenType.arrayOpen,
      CosTokenType.integer,
      CosTokenType.integer,
      CosTokenType.arrayClose,
      CosTokenType.dictClose,
      CosTokenType.keyword,
      CosTokenType.keyword,
      CosTokenType.keyword,
    ]);
  });

  test('comments are skipped', () {
    final tokens = lexAll('42 % the answer\n7');
    expect(tokens.map((t) => t.intValue), [42, 7]);
  });
}
