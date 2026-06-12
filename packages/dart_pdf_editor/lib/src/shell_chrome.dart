import 'package:flutter/material.dart';

import 'editing/editing_color_picker.dart';
import 'editing/editing_preferences.dart';

/// Shared header chrome for the drop-in shells (PdfReader and
/// PdfEditorView). Package-private: not exported from the library.

const double pdfShellCompactWidth = 700;

bool pdfShellShowThumbnailSidebar(
  PdfEditingPreferences preferences,
  BoxConstraints constraints,
) {
  final compact = constraints.maxWidth.isFinite &&
      constraints.maxWidth < pdfShellCompactWidth;
  return preferences.showThumbnailSidebar &&
      (!compact || preferences.hasShowThumbnailSidebarPreference);
}

/// The shells' slim header bar: a leading group (search, page number)
/// and a trailing group (panel toggles), pushed apart when there is
/// room and scrolling horizontally when there isn't.
class PdfShellBar extends StatelessWidget {
  const PdfShellBar({super.key, required this.leading, required this.trailing});

  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SizedBox(
        height: 48,
        // a Spacer can't live in an unbounded-width Row, so the gap
        // comes from spaceBetween over a min-width-constrained Row
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [const SizedBox(width: 8), ...leading],
                  ),
                  Row(
                    children: [...trailing, const SizedBox(width: 8)],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ViewOption { annotations, formHighlight, reflow, pageColor }

/// The "view options" popup both shells offer: display-only settings
/// (annotation visibility, form-field highlight, paper color) that live
/// in [PdfEditingPreferences] and never touch the document.
class PdfShellViewOptionsButton extends StatelessWidget {
  const PdfShellViewOptionsButton({
    super.key,
    required this.preferences,
    this.reflow = false,
  });

  final PdfEditingPreferences preferences;
  final bool reflow;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_ViewOption>(
      key: const ValueKey('pdf-shell-view-options'),
      tooltip: 'View options',
      icon: const Icon(Icons.display_settings_outlined),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelected: (option) async {
        switch (option) {
          case _ViewOption.annotations:
            preferences.showAnnotations = !preferences.showAnnotations;
          case _ViewOption.formHighlight:
            preferences.highlightFormFields = !preferences.highlightFormFields;
          case _ViewOption.reflow:
            preferences.showReflowView = !preferences.showReflowView;
          case _ViewOption.pageColor:
            final color = await showPdfColorPicker(
              context,
              initial: preferences.pageColor,
              initialFormat: preferences.colorPickerFormat,
              onFormatChanged: (format) =>
                  preferences.colorPickerFormat = format,
            );
            if (color != null) preferences.pageColor = color;
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          key: const ValueKey('pdf-shell-show-annotations'),
          value: _ViewOption.annotations,
          checked: preferences.showAnnotations,
          child: const Text('Show annotations'),
        ),
        CheckedPopupMenuItem(
          key: const ValueKey('pdf-shell-highlight-forms'),
          value: _ViewOption.formHighlight,
          checked: preferences.highlightFormFields,
          child: const Text('Highlight form fields'),
        ),
        if (reflow)
          CheckedPopupMenuItem(
            key: const ValueKey('pdf-shell-reflow-view'),
            value: _ViewOption.reflow,
            checked: preferences.showReflowView,
            child: const Text('Reflow text'),
          ),
        const PopupMenuItem(
          key: ValueKey('pdf-shell-page-color'),
          value: _ViewOption.pageColor,
          child: Text('Page color…'),
        ),
      ],
    );
  }
}

/// A compact header toggle for one of the side panels.
class PdfShellToggleButton extends StatelessWidget {
  const PdfShellToggleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(icon),
      tooltip: tooltip,
      isSelected: selected,
      onPressed: onPressed,
    );
  }
}
