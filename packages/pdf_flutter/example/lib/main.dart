import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';

import 'demo_document.dart';

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

  // app state the interactive demo's PDF links and overlays manipulate
  bool _isDemo = false;
  int _counter = 0;
  bool _switchOn = false;
  final _noteField = TextEditingController();

  /// GoTo and the standard named page actions never get here (the viewer
  /// follows them itself). Custom-scheme URIs are dispatched as app
  /// commands — the conventional way a PDF drives its host app — and
  /// anything else just gets described in a snackbar.
  void _onAction(PdfAction action, PdfAnnotation annotation) {
    if (action is PdfUriAction) {
      final uri = Uri.tryParse(action.uri);
      if (uri?.scheme == 'app') {
        switch (uri!.host) {
          case 'counter':
            setState(() => _counter++);
            return;
          case 'message':
            _toast(uri.queryParameters['text'] ?? 'No message');
            return;
        }
      }
    }
    _toast(switch (action) {
      PdfUriAction(:final uri) => 'Link: $uri',
      PdfJavaScriptAction(:final script) =>
        'JavaScript surfaced to the app: $script',
      PdfNamedAction(:final name) => 'Named action: $name',
      PdfUnknownAction(:final type) => 'Unhandled action type: $type',
      PdfGoToAction() => 'GoTo', // unreachable
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  void _openDemo() {
    setState(() {
      _document = PdfDocument.open(buildDemoPdf());
      _title = 'Interactive demo';
      _error = null;
      _isDemo = true;
      _counter = 0;
      _searchField.clear();
    });
  }

  /// Flutter widgets pinned into the slots the demo document draws.
  List<Widget> _demoOverlays(
      BuildContext context, int pageIndex, PdfPageGeometry geometry) {
    switch (pageIndex) {
      case 0:
        return [
          Positioned.fromRect(
            rect: geometry.toViewRect(DemoLayout.counterBadge),
            child: _CounterBadge(count: _counter),
          ),
        ];
      case 1:
        return [
          Positioned.fromRect(
            rect: geometry.toViewRect(DemoLayout.clock),
            child: const _ClockTile(),
          ),
          Positioned.fromRect(
            rect: geometry.toViewRect(DemoLayout.counter),
            child: _CounterControl(
              count: _counter,
              onChanged: (value) => setState(() => _counter = value),
            ),
          ),
          Positioned.fromRect(
            rect: geometry.toViewRect(DemoLayout.toggle),
            child: FittedBox(
              child: Switch(
                value: _switchOn,
                onChanged: (value) => setState(() => _switchOn = value),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: geometry.toViewRect(DemoLayout.note),
            child: Material(
              color: const Color(0xF2FFFFFF),
              shape: RoundedRectangleBorder(
                side: BorderSide(color: Colors.indigo.shade200),
                borderRadius: BorderRadius.circular(4),
              ),
              child: TextField(
                controller: _noteField,
                decoration: const InputDecoration(
                  hintText: 'Type here - this text box floats above the page',
                  isDense: true,
                  contentPadding: EdgeInsets.all(10),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
        ];
      default:
        return const [];
    }
  }

  @override
  void initState() {
    super.initState();
    // open a file straight away with:
    //   flutter run -d macos --dart-define=PDF=/path/to/file.pdf
    const preset = String.fromEnvironment('PDF');
    if (preset.isNotEmpty) {
      _openPath(preset);
    } else {
      _openDemo();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchField.dispose();
    _noteField.dispose();
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
        _isDemo = false;
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
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'Open the interactive demo',
            onPressed: _openDemo,
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open a PDF'),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _openDemo,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Try the interactive demo'),
                ),
              ],
            ),
          ),
        (final PdfDocument document, _) => PdfViewer(
            document: document,
            controller: _controller,
            onAction: _onAction,
            pageOverlayBuilder: _isDemo ? _demoOverlays : null,
          ),
      },
    );
  }
}

/// Shows the counter the PDF's "Increment" link annotation drives —
/// PDF → app state → widget, completing the loop on the same page.
class _CounterBadge extends StatelessWidget {
  const _CounterBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.indigo,
      borderRadius: BorderRadius.circular(6),
      child: Center(
        child: Text(
          '$count',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// Ticks every second — proof the overlay is a live widget, not artwork.
class _ClockTile extends StatefulWidget {
  const _ClockTile();

  @override
  State<_ClockTile> createState() => _ClockTileState();
}

class _ClockTileState extends State<_ClockTile> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer =
        Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    String pad(int v) => v.toString().padLeft(2, '0');
    return Material(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(6),
      child: Center(
        child: Text(
          '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}',
          style: const TextStyle(
            color: Colors.greenAccent,
            fontSize: 18,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Edits the same counter the PDF link on page 1 increments.
class _CounterControl extends StatelessWidget {
  const _CounterControl({required this.count, required this.onChanged});

  final int count;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2FFFFFF),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.indigo.shade200),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: () => onChanged(count - 1),
          ),
          Text('$count', style: Theme.of(context).textTheme.titleMedium),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => onChanged(count + 1),
          ),
        ],
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
