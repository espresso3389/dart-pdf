import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_editor/pdf_editor.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PdfEditingPreferences', () {
    test('changes persist and a fresh instance restores them', () async {
      SharedPreferences.setMockInitialValues({});
      final a = PdfEditingPreferences();
      await a.ready;
      a.color = const Color(0xFF123456);
      a.strokeWidth = 5;
      a.fontSize = 18;
      a.opacity = 0.5;
      a.fingerDrawsInk = false;
      a.showThumbnailSidebar = true;
      a.showAnnotationSidebar = true;
      a.author = 'Ben';
      a.colorPickerFormat = PdfColorFormat.cmyk;
      await pumpEventQueue(); // let the unawaited writes land

      final b = PdfEditingPreferences();
      await b.ready;
      expect(b.color, const Color(0xFF123456));
      expect(b.strokeWidth, 5);
      expect(b.fontSize, 18);
      expect(b.opacity, 0.5);
      expect(b.fingerDrawsInk, isFalse);
      expect(b.showThumbnailSidebar, isTrue);
      expect(b.showAnnotationSidebar, isTrue);
      expect(b.author, 'Ben');
      expect(b.colorPickerFormat, PdfColorFormat.cmyk);
    });

    test('empty storage leaves the defaults', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = PdfEditingPreferences();
      await prefs.ready;
      expect(prefs.color, const Color(0xFFE53935));
      expect(prefs.strokeWidth, 2);
      expect(prefs.fontSize, 14);
      expect(prefs.opacity, 1);
      expect(prefs.fingerDrawsInk, isTrue);
      expect(prefs.showThumbnailSidebar, isFalse);
      expect(prefs.showAnnotationSidebar, isFalse);
      expect(prefs.author, isNull);
      expect(prefs.colorPickerFormat, PdfColorFormat.hex);
    });

    test('a value set while loading is not clobbered by stored data',
        () async {
      SharedPreferences.setMockInitialValues(
          {'pdf_editor.editing.strokeWidth': 9.0});
      final prefs = PdfEditingPreferences()..strokeWidth = 3;
      await prefs.ready;
      expect(prefs.strokeWidth, 3);
    });

    test('a new controller adopts the stored preferences', () async {
      SharedPreferences.setMockInitialValues({
        'pdf_editor.editing.color': 0xFF00A040,
        'pdf_editor.editing.strokeWidth': 6.0,
        'pdf_editor.editing.fontSize': 22.0,
        'pdf_editor.editing.opacity': 0.4,
        'pdf_editor.editing.fingerDrawsInk': false,
      });
      final editing = PdfEditingController(buildMultiPagePdf(1));
      await editing.preferences.ready;
      expect(editing.color, const Color(0xFF00A040));
      expect(editing.strokeWidth, 6);
      expect(editing.fontSize, 22);
      expect(editing.opacity, 0.4);
      expect(editing.fingerDrawsInk, isFalse);
    });

    test('controller setters write through to storage', () async {
      SharedPreferences.setMockInitialValues({});
      final first = PdfEditingController(buildMultiPagePdf(1));
      await first.preferences.ready;
      first
        ..color = const Color(0xFF0000FF)
        ..strokeWidth = 7
        ..opacity = 0.8;
      await pumpEventQueue();

      // a later session: new controller, its own preferences instance
      final second = PdfEditingController(buildMultiPagePdf(1));
      await second.preferences.ready;
      expect(second.color, const Color(0xFF0000FF));
      expect(second.strokeWidth, 7);
      expect(second.opacity, 0.8);
    });

    test('preference changes notify controller listeners', () async {
      SharedPreferences.setMockInitialValues({});
      final editing = PdfEditingController(buildMultiPagePdf(1));
      await editing.preferences.ready;
      var notified = 0;
      editing.addListener(() => notified++);
      editing.preferences.color = const Color(0xFF112233);
      expect(notified, 1);
      expect(editing.color, const Color(0xFF112233));
    });
  });
}
