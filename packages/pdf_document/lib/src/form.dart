import 'package:pdf_cos/pdf_cos.dart';

import 'document.dart';
import 'rect.dart';

/// What kind of input a form field accepts, derived from /FT plus the
/// discriminating /Ff bits (§12.7.4).
enum PdfFieldType {
  text,
  checkBox,
  radioGroup,
  pushButton,
  comboBox,
  listBox,
  signature,
  unknown,
}

/// The document's interactive form (§12.7.2): the catalog's /AcroForm
/// dictionary plus the field tree hanging off /Fields.
class PdfAcroForm {
  PdfAcroForm._(this.document, this.dict);

  /// The document's form, or null if it has none.
  static PdfAcroForm? of(PdfDocument document) {
    final dict = document.cos.resolve(document.catalog['AcroForm']);
    return dict is CosDictionary ? PdfAcroForm._(document, dict) : null;
  }

  final PdfDocument document;

  /// The raw /AcroForm dictionary.
  final CosDictionary dict;

  /// The form-wide /DA default appearance string, if any.
  String? get defaultAppearance {
    final da = document.cos.resolve(dict['DA']);
    return da is CosString ? da.text : null;
  }

  /// The form-wide /DR default resources (fonts the /DA strings name).
  CosDictionary? get defaultResources {
    final dr = document.cos.resolve(dict['DR']);
    return dr is CosDictionary ? dr : null;
  }

  /// Whether the file asks viewers to regenerate appearances themselves.
  bool get needsAppearances {
    final flag = document.cos.resolve(dict['NeedAppearances']);
    return flag is CosBoolean && flag.value;
  }

  List<PdfFormField>? _fields;

  /// All terminal (fillable) fields, depth-first across the field tree.
  List<PdfFormField> get fields => _fields ??= () {
        final out = <PdfFormField>[];
        final roots = document.cos.resolve(dict['Fields']);
        if (roots is CosArray) {
          for (final item in roots.items) {
            final node = document.cos.resolve(item);
            if (node is CosDictionary) {
              _collect(node, '', out, <CosDictionary>{});
            }
          }
        }
        return out;
      }();

  /// Looks up a field by its fully qualified name.
  PdfFormField? fieldNamed(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }

  /// A node with /T-carrying kids is an internal node; a node whose kids
  /// are all widgets (no /T) is a terminal field (§12.7.4.2).
  void _collect(CosDictionary node, String prefix, List<PdfFormField> out,
      Set<CosDictionary> visited) {
    if (!visited.add(node)) return;
    final cos = document.cos;
    final t = cos.resolve(node['T']);
    final partial = t is CosString ? t.text : null;
    final name = switch ((prefix.isEmpty, partial)) {
      (_, null) => prefix,
      (true, _) => partial!,
      (false, _) => '$prefix.$partial',
    };

    final kids = cos.resolve(node['Kids']);
    var hasChildFields = false;
    if (kids is CosArray) {
      for (final item in kids.items) {
        final kid = cos.resolve(item);
        if (kid is CosDictionary && cos.resolve(kid['T']) is CosString) {
          hasChildFields = true;
          _collect(kid, name, out, visited);
        }
      }
    }
    if (!hasChildFields) {
      out.add(PdfFormField._(this, node, name));
    }
  }
}

/// One terminal field of the form: a value plus the widget annotations
/// that display it on pages.
class PdfFormField {
  PdfFormField._(this.form, this.dict, this.name);

  final PdfAcroForm form;

  /// The raw field dictionary (also the widget dictionary when merged).
  final CosDictionary dict;

  /// Fully qualified name: partial /T names joined with dots.
  final String name;

  CosDocument get _cos => form.document.cos;

  /// Resolves an inheritable entry up the /Parent chain (§12.7.4.2).
  CosObject? inherited(String key) {
    CosDictionary? node = dict;
    final visited = <CosDictionary>{};
    while (node != null && visited.add(node)) {
      final value = node.containsKey(key) ? _cos.resolve(node[key]) : null;
      if (value != null && value is! CosNull) return value;
      final parent = _cos.resolve(node['Parent']);
      node = parent is CosDictionary ? parent : null;
    }
    return null;
  }

  /// The /FT name without the slash ('Tx', 'Btn', 'Ch', 'Sig'), inherited.
  String? get fieldTypeName {
    final ft = inherited('FT');
    return ft is CosName ? ft.value : null;
  }

  /// The /Ff field-flag word, inherited.
  int get flags {
    final ff = inherited('Ff');
    return ff is CosInteger ? ff.value : 0;
  }

  PdfFieldType get type => switch (fieldTypeName) {
        'Tx' => PdfFieldType.text,
        'Ch' => flags & comboFlag != 0
            ? PdfFieldType.comboBox
            : PdfFieldType.listBox,
        'Btn' => flags & pushButtonFlag != 0
            ? PdfFieldType.pushButton
            : flags & radioFlag != 0
                ? PdfFieldType.radioGroup
                : PdfFieldType.checkBox,
        'Sig' => PdfFieldType.signature,
        _ => PdfFieldType.unknown,
      };

  static const readOnlyFlag = 1; // bit 1
  static const requiredFlag = 2; // bit 2
  static const multilineFlag = 1 << 12; // bit 13
  static const passwordFlag = 1 << 13; // bit 14
  static const radioFlag = 1 << 15; // bit 16
  static const pushButtonFlag = 1 << 16; // bit 17
  static const comboFlag = 1 << 17; // bit 18
  static const editFlag = 1 << 18; // bit 19

  bool get isReadOnly => flags & readOnlyFlag != 0;
  bool get isRequired => flags & requiredFlag != 0;
  bool get isMultiline => flags & multilineFlag != 0;
  bool get isPassword => flags & passwordFlag != 0;

  /// /Q quadding: 0 left (default), 1 centered, 2 right.
  int get quadding {
    final q = inherited('Q');
    return q is CosInteger ? q.value : 0;
  }

  /// The field's /DA string, falling back to the form-wide default.
  String? get defaultAppearance {
    final da = inherited('DA');
    return da is CosString ? da.text : form.defaultAppearance;
  }

  /// The current value as text: /V strings come back verbatim, button
  /// state names without the slash, multi-select arrays as their first
  /// string. Null when the field is empty.
  String? get value {
    final v = inherited('V');
    if (v is CosString) return v.text;
    if (v is CosName) return v.value;
    if (v is CosArray && v.length > 0) {
      final first = _cos.resolve(v[0]);
      if (first is CosString) return first.text;
    }
    return null;
  }

  /// Whether a check box or radio group is on (/V set and not /Off).
  bool get isChecked {
    final v = inherited('V');
    return v is CosName && v.value != 'Off';
  }

  /// The widget annotations displaying this field: its /Kids without a
  /// /T of their own, or the field dictionary itself when merged.
  List<CosDictionary> get widgets {
    final kids = _cos.resolve(dict['Kids']);
    if (kids is CosArray) {
      final out = <CosDictionary>[];
      for (final item in kids.items) {
        final kid = _cos.resolve(item);
        if (kid is CosDictionary && _cos.resolve(kid['T']) is! CosString) {
          out.add(kid);
        }
      }
      if (out.isNotEmpty) return out;
    }
    return [dict];
  }

  /// The rectangle of widget [index] in page space.
  PdfRect? widgetRect(int index) =>
      pdfRectFrom(_cos, widgets[index]['Rect']);

  /// The on-state names a button's widgets define: the keys of each
  /// /AP /N state dictionary except 'Off'. A plain check box has one
  /// (conventionally 'Yes'); a radio group has one per button.
  List<String> get onStates {
    final out = <String>[];
    for (final widget in widgets) {
      final ap = _cos.resolve(widget['AP']);
      if (ap is! CosDictionary) continue;
      final n = _cos.resolve(ap['N']);
      if (n is! CosDictionary) continue;
      for (final key in n.entries.keys) {
        if (key != 'Off' && !out.contains(key)) out.add(key);
      }
    }
    return out;
  }

  /// Choice options as (exportValue, displayValue) pairs. /Opt entries are
  /// either plain strings or [export display] pairs (§12.7.5.4).
  List<(String, String)> get options {
    final opt = inherited('Opt');
    if (opt is! CosArray) return const [];
    final out = <(String, String)>[];
    for (final item in opt.items) {
      final entry = _cos.resolve(item);
      if (entry is CosString) {
        out.add((entry.text, entry.text));
      } else if (entry is CosArray && entry.length >= 2) {
        final export = _cos.resolve(entry[0]);
        final display = _cos.resolve(entry[1]);
        if (export is CosString && display is CosString) {
          out.add((export.text, display.text));
        }
      }
    }
    return out;
  }
}
