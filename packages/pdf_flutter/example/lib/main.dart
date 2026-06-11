import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_flutter/pdf_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'demo_document.dart';

/// One filter, every platform: desktop and web match on the extension,
/// Android on the MIME type, iOS/macOS on the uniform type identifier —
/// a type group missing the field a platform filters by throws there.
const _pdfTypeGroup = XTypeGroup(
  label: 'PDF documents',
  extensions: ['pdf'],
  mimeTypes: ['application/pdf'],
  uniformTypeIdentifiers: ['com.adobe.pdf'],
);

/// Images the form tool's push-button fill accepts.
const _imageTypeGroup = XTypeGroup(
  label: 'Images',
  extensions: ['png', 'jpg', 'jpeg'],
  mimeTypes: ['image/png', 'image/jpeg'],
  uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
);

/// The form tool's image picker: tapped push-button fields (signature
/// and logo slots in templates) fill with the chosen PNG or JPEG.
Future<Uint8List?> _pickFormImage(BuildContext context, PdfFormField field) =>
    openFile(acceptedTypeGroups: const [_imageTypeGroup])
        .then((file) => file?.readAsBytes());

void main() => runApp(const ViewerApp());

class ViewerApp extends StatefulWidget {
  const ViewerApp({super.key});

  @override
  State<ViewerApp> createState() => _ViewerAppState();
}

class _ViewerAppState extends State<ViewerApp> {
  /// UI preferences saved on this device — tool styles, which panels
  /// are open, and the theme mode. Owned here so the MaterialApp can
  /// follow the persisted light/dark choice; the screen below shares
  /// the same instance with every editing session.
  final _prefs = PdfEditingPreferences();

  @override
  void dispose() {
    _prefs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _prefs,
      builder: (context, _) => MaterialApp(
        title: 'dart-pdf viewer',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        themeMode: _prefs.themeMode,
        home: ViewerScreen(prefs: _prefs),
      ),
    );
  }
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.prefs});

  final PdfEditingPreferences prefs;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _controller = PdfViewerController();
  final _searchField = TextEditingController();
  final _searchFocus = FocusNode();

  PdfEditingPreferences get _prefs => widget.prefs;

  /// The open document's editing session: owns the bytes, the document
  /// revisions, undo/redo, and the editing tool state.
  PdfEditingController? _editing;
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

  /// The app's own entries in the annotation right-click menu — here a
  /// "Copy text" action when the clicked annotation carries any.
  List<PdfAnnotationMenuItem> _annotationMenuActions(
      BuildContext context, PdfAnnotationMenuRequest request) {
    final contents = request.primary?.contents;
    if (contents == null || contents.isEmpty) return const [];
    return [
      PdfAnnotationMenuItem(
        label: 'Copy text',
        icon: Icons.copy_outlined,
        onSelected: (request) {
          Clipboard.setData(ClipboardData(text: contents));
          _toast('Annotation text copied');
        },
      ),
    ];
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  void _openBytes(Uint8List bytes, String title, {bool isDemo = false}) {
    final previous = _editing;
    setState(() {
      _editing = PdfEditingController(bytes, preferences: _prefs);
      _title = title;
      _error = null;
      _isDemo = isDemo;
      if (isDemo) _counter = 0;
      _searchField.clear();
    });
    previous?.dispose();
  }

  void _openDemo() =>
      _openBytes(buildDemoPdf(), 'Feature showcase', isDemo: true);

  /// Pins [child] into a page slot at its design size in PDF points and
  /// lets it scale with the page, so the overlays hold together at any
  /// zoom level and on any screen size.
  Widget _slot(PdfPageGeometry geometry, PdfRect rect, Widget child) =>
      Positioned.fromRect(
        rect: geometry.toViewRect(rect),
        child: FittedBox(
          child: SizedBox(width: rect.width, height: rect.height, child: child),
        ),
      );

  /// Flutter widgets pinned into the slots the demo document draws.
  List<Widget> _demoOverlays(
      BuildContext context, int pageIndex, PdfPageGeometry geometry) {
    switch (pageIndex) {
      case 0:
        return [
          _slot(geometry, DemoLayout.counterBadge,
              _CounterBadge(count: _counter)),
        ];
      case 1:
        return [
          _slot(geometry, DemoLayout.clock, const _ClockTile()),
          _slot(
            geometry,
            DemoLayout.counter,
            _CounterControl(
              count: _counter,
              onChanged: (value) => setState(() => _counter = value),
            ),
          ),
          _slot(
            geometry,
            DemoLayout.toggle,
            FittedBox(
              child: Switch(
                value: _switchOn,
                onChanged: (value) => setState(() => _switchOn = value),
              ),
            ),
          ),
          _slot(
            geometry,
            DemoLayout.note,
            Material(
              color: const Color(0xF2FFFFFF),
              shape: RoundedRectangleBorder(
                side: BorderSide(color: Colors.indigo.shade200),
                borderRadius: BorderRadius.circular(4),
              ),
              child: TextField(
                key: const ValueKey('demo-note'),
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
    // repaint the chrome when a preference (panel visibility) changes
    _prefs.addListener(_onPrefsChanged);
    // open a file straight away with:
    //   flutter run -d macos --dart-define=PDF=/path/to/file.pdf
    const preset = String.fromEnvironment('PDF');
    if (preset.isNotEmpty) {
      _openPath(preset);
    } else {
      _openDemo();
    }
  }

  void _onPrefsChanged() => setState(() {});

  /// ⌘F / Ctrl+F: jump to the search field, ready to overtype.
  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchField.selection =
        TextSelection(baseOffset: 0, extentOffset: _searchField.text.length);
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefsChanged);
    _controller.dispose();
    _searchField.dispose();
    _searchFocus.dispose();
    _noteField.dispose();
    _editing?.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: const [_pdfTypeGroup]);
    if (file == null) return;
    try {
      _openBytes(await file.readAsBytes(), file.name);
    } catch (e) {
      setState(() => _error = 'Could not open ${file.name}\n$e');
    }
  }

  Future<void> _openPath(String path) async {
    try {
      final bytes = await XFile(path).readAsBytes();
      _openBytes(bytes, path.split(RegExp(r'[/\\]')).last);
    } catch (e) {
      setState(() => _error = 'Could not open $path\n$e');
    }
  }

  /// Saves with whatever the platform offers: a save dialog on desktop,
  /// a browser download on the web, the share sheet on phones and
  /// tablets (where apps can't write outside their sandbox directly).
  Future<void> _saveAs(Uint8List bytes) async {
    const name = 'annotated.pdf';
    final file = XFile.fromData(bytes, mimeType: 'application/pdf');
    if (kIsWeb) {
      await file.saveTo(name);
      _toast('Downloaded $name');
      return;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android || TargetPlatform.iOS:
        final box = context.findRenderObject() as RenderBox?;
        final origin =
            box == null ? null : box.localToGlobal(Offset.zero) & box.size;
        await SharePlus.instance.share(ShareParams(
          files: [file],
          fileNameOverrides: const [name],
          // required on iPad: the share popover anchors to this rect
          sharePositionOrigin: origin ?? const Rect.fromLTWH(0, 0, 1, 1),
        ));
      default:
        final location = await getSaveLocation(
          suggestedName: name,
          acceptedTypeGroups: const [_pdfTypeGroup],
        );
        if (location == null) return;
        try {
          await file.saveTo(location.path);
          _toast('Saved to ${location.path}');
        } catch (e) {
          _toast('Save failed: $e');
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    // the inline search field fits a desktop app bar; narrow (phone)
    // layouts get a slim second row instead
    final wideBar = MediaQuery.sizeOf(context).width >= 720;
    // shortcuts bubble up the focus tree, so wrapping the scaffold catches
    // them with focus anywhere inside — including on the viewer itself
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title.isEmpty ? 'dart-pdf viewer' : _title,
              overflow: TextOverflow.ellipsis),
          actions: [
            if (editing != null && wideBar) ...[
              Center(
                child: PdfSearchField(
                  controller: _controller,
                  searchController: _searchField,
                  focusNode: _searchFocus,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.manage_search),
                tooltip: 'Search results',
                isSelected: _prefs.showSearchResultsPanel,
                onPressed: () => _prefs.showSearchResultsPanel =
                    !_prefs.showSearchResultsPanel,
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: PdfPageNumberField(controller: _controller)),
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
            if (editing != null) ...[
              IconButton(
                icon: const Icon(Icons.grid_view),
                tooltip: 'Pages',
                isSelected: _prefs.showThumbnailSidebar,
                onPressed: () =>
                    _prefs.showThumbnailSidebar = !_prefs.showThumbnailSidebar,
              ),
              IconButton(
                icon: const Icon(Icons.list_alt),
                tooltip: 'Annotations',
                isSelected: _prefs.showAnnotationSidebar,
                onPressed: () => _prefs.showAnnotationSidebar =
                    !_prefs.showAnnotationSidebar,
              ),
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: 'Properties',
                isSelected: _prefs.showPropertiesPanel,
                onPressed: () =>
                    _prefs.showPropertiesPanel = !_prefs.showPropertiesPanel,
              ),
              IconButton(
                icon: const Icon(Icons.person_outline),
                tooltip: 'Author name',
                onPressed: () async {
                  final name = await showPdfTextPrompt(context,
                      title: 'Author name', initial: editing.author ?? '');
                  if (name == null) return;
                  editing.author = name.trim().isEmpty ? null : name.trim();
                },
              ),
            ],
            IconButton(
              icon: const Icon(Icons.format_color_fill),
              tooltip: 'Page color',
              onPressed: () async {
                final color = await showPdfColorPicker(context,
                    initial: _prefs.pageColor,
                    initialFormat: _prefs.colorPickerFormat,
                    onFormatChanged: (format) =>
                        _prefs.colorPickerFormat = format);
                if (color != null) _prefs.pageColor = color;
              },
            ),
            IconButton(
              icon: Icon(switch (_prefs.themeMode) {
                ThemeMode.system => Icons.brightness_auto,
                ThemeMode.light => Icons.light_mode,
                ThemeMode.dark => Icons.dark_mode,
              }),
              tooltip: switch (_prefs.themeMode) {
                ThemeMode.system => 'Theme: system — tap for light',
                ThemeMode.light => 'Theme: light — tap for dark',
                ThemeMode.dark => 'Theme: dark — tap for system',
              },
              onPressed: () => _prefs.themeMode = switch (_prefs.themeMode) {
                ThemeMode.system => ThemeMode.light,
                ThemeMode.light => ThemeMode.dark,
                ThemeMode.dark => ThemeMode.system,
              },
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
          bottom: editing == null || wideBar
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Row(children: [
                      PdfSearchField(
                        controller: _controller,
                        searchController: _searchField,
                        focusNode: _searchFocus,
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.manage_search),
                        tooltip: 'Search results',
                        isSelected: _prefs.showSearchResultsPanel,
                        onPressed: () => _prefs.showSearchResultsPanel =
                            !_prefs.showSearchResultsPanel,
                      ),
                    ]),
                  ),
                ),
        ),
        body: switch ((editing, _error)) {
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
          // the editing controller owns the document revisions: rebuild the
          // viewer with the current one whenever the controller notifies
          // the children are keyed so a panel appearing or disappearing
          // never recreates the viewer element (which would reset the
          // reading position and re-run the initial fit)
          (final PdfEditingController session, _) => Row(children: [
              if (_prefs.showThumbnailSidebar)
                PdfThumbnailSidebar(
                  key: const ValueKey('thumbnail-sidebar'),
                  controller: session,
                  viewerController: _controller,
                  pageColor: _prefs.pageColor,
                ),
              if (_prefs.showSearchResultsPanel)
                PdfSearchResultsPanel(
                  key: const ValueKey('search-panel'),
                  controller: _controller,
                  preferences: _prefs,
                ),
              Expanded(
                key: const ValueKey('viewer'),
                child: ListenableBuilder(
                  listenable: session,
                  builder: (context, _) => PdfViewer(
                    document: session.document,
                    controller: _controller,
                    onAction: _onAction,
                    pageOverlayBuilder: _isDemo ? _demoOverlays : null,
                    editing: session,
                    annotationMenuBuilder: _annotationMenuActions,
                    formImagePicker: _pickFormImage,
                    pageColor: _prefs.pageColor,
                  ),
                ),
              ),
              if (_prefs.showAnnotationSidebar)
                PdfAnnotationSidebar(
                  key: const ValueKey('annotation-sidebar'),
                  controller: session,
                  viewerController: _controller,
                ),
              if (_prefs.showPropertiesPanel)
                PdfAnnotationPropertiesPanel(
                  key: const ValueKey('properties-panel'),
                  controller: session,
                ),
            ]),
        },
        bottomNavigationBar: editing == null
            ? null
            : PdfEditingToolbar(
                controller: editing,
                viewerController: _controller,
                onSave: (bytes) => unawaited(_saveAs(bytes)),
              ),
      ),
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
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
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

