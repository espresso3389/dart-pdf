import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';

void main() => runApp(const ViewerApp());

class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dart-pdf viewer',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ViewerScreen(),
    );
  }
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _controller = PdfViewerController();
  final _searchField = TextEditingController();
  PdfDocument? _document;
  String _title = '';
  String? _error;
  bool _showOverlays = false;

  void _onAction(PdfAction action, PdfAnnotation annotation) {
    // GoTo and the standard named page actions never get here (the viewer
    // follows them itself); this is where an app dispatches its own
    // custom-scheme URIs, opens external links, etc.
    final description = switch (action) {
      PdfUriAction(:final uri) => 'Link: $uri',
      PdfJavaScriptAction(:final script) =>
        'JavaScript action: ${script.length > 60 ? script.substring(0, 60) : script}',
      PdfNamedAction(:final name) => 'Named action: $name',
      PdfUnknownAction(:final type) => 'Unhandled action type: $type',
      PdfGoToAction() => 'GoTo', // unreachable
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(description),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  void initState() {
    super.initState();
    // open a file straight away with:
    //   flutter run -d macos --dart-define=PDF=/path/to/file.pdf
    const preset = String.fromEnvironment('PDF');
    if (preset.isNotEmpty) _openPath(preset);
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchField.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'PDF documents', extensions: ['pdf']),
    ]);
    if (file != null) await _openPath(file.path);
  }

  Future<void> _openPath(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final document = PdfDocument.open(bytes);
      setState(() {
        _document = document;
        _title = path.split(Platform.pathSeparator).last;
        _error = null;
        _searchField.clear();
      });
    } catch (e) {
      setState(() => _error = 'Could not open $path\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title.isEmpty ? 'dart-pdf viewer' : _title,
            overflow: TextOverflow.ellipsis),
        actions: [
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _controller.pageCount == 0
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: Text(
                        '${_controller.currentPage + 1} / '
                        '${_controller.pageCount}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
          ),
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => !_controller.hasSelection
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy selected text (⌘C)',
                    onPressed: () async {
                      await _controller.copySelection();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
          ),
          if (_document != null)
            IconButton(
              icon: Icon(_showOverlays ? Icons.layers : Icons.layers_outlined),
              tooltip: 'Toggle widget overlay demo',
              onPressed: () => setState(() => _showOverlays = !_showOverlays),
            ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Open PDF',
            onPressed: _pickFile,
          ),
        ],
        bottom: _document == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child:
                    _SearchBar(controller: _controller, field: _searchField),
              ),
      ),
      body: switch ((_document, _error)) {
        (_, final String error) => Center(
            child: Text(error, textAlign: TextAlign.center),
          ),
        (null, _) => Center(
            child: FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open a PDF'),
            ),
          ),
        (final PdfDocument document, _) => PdfViewer(
            document: document,
            controller: _controller,
            onAction: _onAction,
            pageOverlayBuilder: !_showOverlays
                ? null
                : (context, pageIndex, geometry) => [
                      // a live Flutter widget pinned to page coordinates:
                      // a sticky note at 1in from the page's top-left
                      if (pageIndex == _controller.currentPage)
                        Positioned.fromRect(
                          rect: geometry.toViewRect(PdfRect(
                            geometry.cropBox.left + 72,
                            geometry.cropBox.top - 144,
                            geometry.cropBox.left + 216,
                            geometry.cropBox.top - 72,
                          )),
                          child: _StickyNote(pageIndex: pageIndex),
                        ),
                    ],
          ),
      },
    );
  }
}

/// Overlay demo: an interactive Material widget living on the page,
/// scrolling and zooming with it.
class _StickyNote extends StatefulWidget {
  const _StickyNote({required this.pageIndex});

  final int pageIndex;

  @override
  State<_StickyNote> createState() => _StickyNoteState();
}

class _StickyNoteState extends State<_StickyNote> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xEEFFF59D),
      elevation: 2,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: () => setState(() => _taps++),
        child: Center(
          child: Text(
            'Flutter widget on page ${widget.pageIndex + 1}\n'
            'taps: $_taps',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.field});

  final PdfViewerController controller;
  final TextEditingController field;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: field,
            decoration: const InputDecoration(
              hintText: 'Search document…',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: controller.search,
          ),
        ),
        const SizedBox(width: 8),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            if (controller.isSearching) {
              return const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            if (controller.query.isEmpty) return const SizedBox.shrink();
            return Row(mainAxisSize: MainAxisSize.min, children: [
              Text(controller.matchCount == 0
                  ? 'No matches'
                  : '${controller.currentMatch + 1} of '
                      '${controller.matchCount}'),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up),
                onPressed: controller.matchCount == 0
                    ? null
                    : controller.previousMatch,
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed:
                    controller.matchCount == 0 ? null : controller.nextMatch,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear search',
                onPressed: () {
                  field.clear();
                  controller.clearSearch();
                },
              ),
            ]);
          },
        ),
      ]),
    );
  }
}
