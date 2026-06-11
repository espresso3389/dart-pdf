import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A compact full-spectrum color picker: a saturation/value area, a hue
/// slider, and a hex field, kept in sync. Annotation opacity is a
/// separate controller property, so the picker deals in opaque colors.
///
/// Used by [showPdfColorPicker]; embed it directly for custom chrome.
class PdfColorPicker extends StatefulWidget {
  const PdfColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<PdfColorPicker> createState() => _PdfColorPickerState();
}

class _PdfColorPickerState extends State<PdfColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color);
  late final TextEditingController _hex =
      TextEditingController(text: _hexOf(widget.color));

  static String _hexOf(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .toUpperCase()
      .padLeft(6, '0');

  Color get _color => _hsv.toColor().withValues(alpha: 1);

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  /// From the SV area or hue slider: update the model and the hex field.
  void _setHsv(HSVColor hsv) {
    setState(() => _hsv = hsv);
    _hex.text = _hexOf(_color);
    widget.onChanged(_color);
  }

  void _setHex(String text) {
    if (text.length != 6) return;
    final value = int.tryParse(text, radix: 16);
    if (value == null) return;
    setState(() => _hsv = HSVColor.fromColor(Color(0xFF000000 | value)));
    widget.onChanged(_color);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SaturationValueArea(hsv: _hsv, onChanged: _setHsv),
          const SizedBox(height: 12),
          _HueSlider(hsv: _hsv, onChanged: _setHsv),
          const SizedBox(height: 12),
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _color,
                shape: BoxShape.circle,
                border:
                    Border.all(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _hex,
                onChanged: _setHex,
                maxLength: 6,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                ],
                decoration: const InputDecoration(
                  prefixText: '#',
                  counterText: '',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// The square: saturation left→right, value bottom→top, at the current hue.
class _SaturationValueArea extends StatelessWidget {
  const _SaturationValueArea({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _pick(Offset position, Size size) {
    onChanged(hsv
        .withSaturation((position.dx / size.width).clamp(0.0, 1.0))
        .withValue(1 - (position.dy / size.height).clamp(0.0, 1.0)));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: LayoutBuilder(builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (d) => _pick(d.localPosition, size),
          onPanUpdate: (d) => _pick(d.localPosition, size),
          child: CustomPaint(
            painter: _SaturationValuePainter(hsv),
            size: size,
          ),
        );
      }),
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  const _SaturationValuePainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas
      ..drawRect(
          rect,
          Paint()
            ..shader =
                LinearGradient(colors: [Colors.white, hue]).createShader(rect))
      ..drawRect(
          rect,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black],
            ).createShader(rect));
    final thumb =
        Offset(hsv.saturation * size.width, (1 - hsv.value) * size.height);
    canvas
      ..drawCircle(
          thumb, 8, Paint()..color = hsv.toColor().withValues(alpha: 1))
      ..drawCircle(
          thumb,
          8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SaturationValuePainter old) => old.hsv != hsv;
}

class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _pick(Offset position, Size size) {
    onChanged(
        hsv.withHue((position.dx / size.width).clamp(0.0, 1.0) * 360 % 360));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: LayoutBuilder(builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (d) => _pick(d.localPosition, size),
          onPanUpdate: (d) => _pick(d.localPosition, size),
          child: CustomPaint(painter: _HuePainter(hsv.hue), size: size),
        );
      }),
    );
  }
}

class _HuePainter extends CustomPainter {
  const _HuePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(10)),
        Paint()
          ..shader = LinearGradient(colors: [
            for (var h = 0; h <= 360; h += 60)
              HSVColor.fromAHSV(1, h % 360.0, 1, 1).toColor(),
          ]).createShader(rect));
    final x = hue / 360 * size.width;
    canvas
      ..drawCircle(Offset(x, size.height / 2), 8,
          Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor())
      ..drawCircle(
          Offset(x, size.height / 2),
          8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_HuePainter old) => old.hue != hue;
}

/// Shows [PdfColorPicker] in a dialog. Returns the chosen color, or null
/// when dismissed.
Future<Color?> showPdfColorPicker(
  BuildContext context, {
  required Color initial,
}) {
  var current = initial;
  return showDialog<Color>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Color'),
      content: PdfColorPicker(
        color: initial,
        onChanged: (color) => current = color,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(current),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
