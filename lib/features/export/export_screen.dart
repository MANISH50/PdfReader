import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoDialogAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../core/models/annotation.dart';
import '../../core/models/document_ref.dart';
import '../../core/models/export_job.dart';
import '../../core/providers.dart';
import '../../ui/design_system/adaptive.dart';
import '../../ui/design_system/tokens.dart' show Space, kMinTouchTarget;
import 'export_support.dart';
import 'exporters.dart';
import 'page_range.dart';

/// Shown before converting to DOCX/TXT.
const String kLossyExportWarning = 'Text and basic layout are kept; complex layouts, tables, columns and fonts '
    'may not convert perfectly. Everything happens on your phone; nothing is uploaded.';

enum PageChoice { all, current, range, selected }

/// Export / convert a document: PDF (with edits), PNG, JPG, TXT, DOCX.
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({
    super.key,
    required this.document,
    this.currentPage,
    this.selectedPages,
    this.initialFormat,
  });

  final DocumentRef document;

  /// 1-based page shown in the viewer; defaults to the saved reading position.
  final int? currentPage;

  /// Pages selected in the organiser, if any.
  final List<int>? selectedPages;
  final ExportFormat? initialFormat;

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

enum _Phase { loading, openFailed, ready, running, done }

class _ExportScreenState extends ConsumerState<ExportScreen> {
  _Phase _phase = _Phase.loading;
  PdfDocument? _doc;
  int _currentPage = 1;
  List<Annotation> _annotations = const [];

  late ExportFormat _format = widget.initialFormat ?? ExportFormat.pdf;
  PageChoice _pages = PageChoice.all;
  final _rangeCtrl = TextEditingController();
  String? _rangeError;
  int _dpi = 150;
  int _jpgQuality = 90;
  bool _includeAnnotations = true;

  int _done = 0, _total = 0;
  bool _cancelRequested = false;
  ExportResult? _result;
  String? _message;
  final _ownedFiles = <String>{};
  late final String _tempDir;
  Future<void>? _running;

  @override
  void initState() {
    super.initState();
    _tempDir = ref.read(tempFilesProvider).dir.path;
    if (widget.selectedPages?.isNotEmpty ?? false) _pages = PageChoice.selected;
    unawaited(_open());
  }

  @override
  void dispose() {
    _rangeCtrl.dispose();
    _cancelRequested = true;
    final doc = _doc;
    void finish() {
      unawaited(doc?.dispose());
      _cleanup();
    }

    // Never dispose the document under a running export; clean up after it.
    final running = _running;
    if (running == null) {
      finish();
    } else {
      unawaited(running.whenComplete(finish));
    }
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final doc = await ref.read(documentServiceProvider).open(widget.document, askPassword: _askPassword);
      if (!mounted) {
        await doc.dispose();
        return;
      }
      var current = widget.currentPage;
      var annotations = const <Annotation>[];
      try {
        current ??= (await ref.read(readingStateStoreProvider).load(widget.document.id)).pageNumber;
        annotations = await ref.read(annotationStoreProvider).load(widget.document.id);
      } catch (_) {
        // optional context; export still works without it
      }
      if (!mounted) {
        await doc.dispose();
        return;
      }
      setState(() {
        _doc = doc;
        _currentPage = (current ?? 1).clamp(1, doc.pages.length);
        _annotations = annotations;
        _phase = _Phase.ready;
      });
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.openFailed);
    }
  }

  Future<String?> _askPassword({required bool retry}) async {
    if (!mounted) return null;
    final ctrl = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(retry ? 'Wrong password' : 'Password required'),
          content: TextField(
            key: const Key('password.field'),
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (v) => Navigator.pop(c, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
                key: const Key('password.ok'),
                onPressed: () => Navigator.pop(c, ctrl.text),
                child: const Text('Open')),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }

  int get _pageCount => _doc?.pages.length ?? 0;

  /// Selected pages, or null for all; throws nothing, sets [_rangeError].
  List<int>? _resolvePages() {
    switch (_pages) {
      case PageChoice.all:
        return null;
      case PageChoice.current:
        return [_currentPage];
      case PageChoice.selected:
        return resolvePages(widget.selectedPages, _pageCount);
      case PageChoice.range:
        final r = PageRangeParser.parse(_rangeCtrl.text, _pageCount);
        return r.isValid ? r.pages : null;
    }
  }

  bool get _canExport {
    if (_phase != _Phase.ready && _phase != _Phase.done) return false;
    if (_pages == PageChoice.range) return PageRangeParser.parse(_rangeCtrl.text, _pageCount).isValid;
    if (_pages == PageChoice.selected) return resolvePages(widget.selectedPages, _pageCount).isNotEmpty;
    return true;
  }

  Future<bool> _confirmLossy() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog.adaptive(
        title: const Text('Before you convert'),
        content: const Text(kLossyExportWarning),
        actions: [
          adaptiveDialogAction(c, label: 'Cancel', onPressed: () => Navigator.pop(c, false)),
          adaptiveDialogAction(c,
              key: const Key('export.confirmLossy'),
              label: 'Convert',
              isDefault: true,
              onPressed: () => Navigator.pop(c, true)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _startExport() async {
    final doc = _doc;
    if (doc == null || !_canExport) return;
    if (_format.isLossyLayout && !(await _confirmLossy())) return;
    if (!mounted) return;
    final run = _export(doc);
    _running = run;
    try {
      await run;
    } finally {
      if (identical(_running, run)) _running = null;
    }
  }

  Future<void> _export(PdfDocument doc) async {
    _cleanup();
    final exporter = exporterFor(ref.read(exportersProvider), _format);
    if (exporter == null) {
      setState(() => _message = 'This format is not available yet.');
      return;
    }
    final pages = _resolvePages();
    setState(() {
      _phase = _Phase.running;
      _cancelRequested = false;
      _done = 0;
      _total = pages?.length ?? _pageCount;
      _result = null;
      _message = null;
    });
    try {
      final result = await exporter.export(
        doc,
        ExportOptions(
          format: _format,
          pages: pages,
          dpi: _dpi,
          jpgQuality: _jpgQuality,
          includeAnnotations: _includeAnnotations,
        ),
        baseName: widget.document.baseName,
        annotations: _annotations,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() {
            _done = d;
            _total = t;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      // Registered before the mounted check so dispose's cleanup removes them.
      _ownedFiles.addAll(result.files);
      if (!mounted) return;
      for (final n in noticesOf(result)) {
        _snack(n);
      }
      setState(() {
        _result = result;
        _phase = _Phase.done;
      });
    } on ExportCancelledException {
      if (mounted) _fail('Export cancelled.');
    } on ExportFailure catch (e) {
      if (mounted) _fail(e.userMessage);
    } catch (_) {
      if (mounted) _fail('Export failed. Please try again.');
    }
  }

  void _fail(String message) => setState(() {
        _phase = _Phase.ready;
        _message = message;
      });

  Future<void> _share() async {
    final r = _result;
    if (r == null) return;
    try {
      await ref.read(shareServiceProvider).shareFiles(r.files, subject: widget.document.baseName);
    } catch (_) {
      _snack('Sharing is not available right now.');
    }
  }

  Future<void> _saveAs() async {
    final r = _result;
    if (r == null) return;
    try {
      final String source;
      final String name;
      if (r.files.length == 1) {
        source = r.files.single;
        name = p.basename(source);
      } else {
        name = '${sanitizeBaseName(widget.document.baseName)}_${_format.extension}.zip';
        source = p.join(p.dirname(r.files.first), name);
        await zipFiles(r.files, source);
        _ownedFiles.add(source);
      }
      final dest = await ref.read(filePickServiceProvider).saveAs(source, suggestedName: name);
      if (dest != null) _snack('Saved.');
    } catch (_) {
      _snack('Saving is not available right now.');
    }
  }

  /// Removes this screen's export output from app temp storage.
  /// Synchronous on purpose: it also runs from [dispose]; only a few files.
  void _cleanup() {
    final files = _ownedFiles.toList();
    _ownedFiles.clear();
    final tempDir = _tempDir;
    final dirs = <String>{};
    for (final f in files) {
      try {
        final file = File(f);
        if (file.existsSync()) file.deleteSync();
        final d = p.dirname(f);
        if (p.isWithin(tempDir, d)) dirs.add(d);
      } on FileSystemException {
        // best effort
      }
    }
    for (final d in dirs) {
      try {
        Directory(d).deleteSync(recursive: true);
      } on FileSystemException {
        // best effort
      }
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Export ${widget.document.displayName}', overflow: TextOverflow.ellipsis)),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator.adaptive());
      case _Phase.openFailed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Text("This document couldn't be opened for export.",
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
          ),
        );
      case _Phase.ready:
      case _Phase.running:
      case _Phase.done:
        return _form(context);
    }
  }

  Widget _form(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final running = _phase == _Phase.running;
    final isImage = _format == ExportFormat.png || _format == ExportFormat.jpg;
    return ListView(
      padding: const EdgeInsets.all(Space.md),
      children: [
        Text('Format', style: t.titleMedium),
        const SizedBox(height: Space.sm),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
          for (final f in ExportFormat.values)
            ChoiceChip(
              key: Key('export.format.${f.extension}'),
              label: Text(_formatLabel(f)),
              selected: _format == f,
              onSelected: running ? null : (_) => setState(() => _format = f),
            ),
        ]),
        if (_format.isLossyLayout) ...[
          const SizedBox(height: Space.md),
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline),
                const SizedBox(width: Space.sm),
                Expanded(child: Text(kLossyExportWarning, style: t.bodyMedium)),
              ]),
            ),
          ),
        ],
        const SizedBox(height: Space.lg),
        Text('Pages', style: t.titleMedium),
        RadioGroup<PageChoice>(
          groupValue: _pages,
          onChanged: (v) {
            if (!running && v != null) setState(() => _pages = v);
          },
          child: Column(children: [
            RadioListTile<PageChoice>(
                value: PageChoice.all, title: Text('All pages ($_pageCount)'), enabled: !running),
            RadioListTile<PageChoice>(
                value: PageChoice.current, title: Text('Current page ($_currentPage)'), enabled: !running),
            if (widget.selectedPages?.isNotEmpty ?? false)
              RadioListTile<PageChoice>(
                value: PageChoice.selected,
                title: Text('Selected pages (${PageRangeParser.format(widget.selectedPages!)})'),
                enabled: !running,
              ),
            RadioListTile<PageChoice>(value: PageChoice.range, title: const Text('Page range'), enabled: !running),
          ]),
        ),
        if (_pages == PageChoice.range)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: TextField(
              controller: _rangeCtrl,
              enabled: !running,
              keyboardType: TextInputType.text,
              decoration: InputDecoration(
                labelText: 'Pages',
                hintText: 'e.g. 1-3, 5',
                errorText: _rangeError,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() {
                final r = PageRangeParser.parse(v, _pageCount);
                _rangeError = v.trim().isEmpty ? null : r.error;
              }),
            ),
          ),
        if (isImage) ...[
          const SizedBox(height: Space.lg),
          Text('Resolution', style: t.titleMedium),
          const SizedBox(height: Space.sm),
          Wrap(spacing: Space.sm, children: [
            for (final d in const [72, 150, 300, 600])
              ChoiceChip(
                label: Text('$d DPI'),
                selected: _dpi == d,
                onSelected: running ? null : (_) => setState(() => _dpi = d),
              ),
          ]),
          if (_dpi >= 300)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text('Very large pages are scaled down to stay within memory limits.', style: t.bodySmall),
            ),
        ],
        if (_format == ExportFormat.jpg) ...[
          const SizedBox(height: Space.md),
          Text('JPG quality: $_jpgQuality', style: t.titleMedium),
          Slider.adaptive(
            value: _jpgQuality.toDouble(),
            min: 50,
            max: 100,
            divisions: 10,
            label: '$_jpgQuality',
            onChanged: running ? null : (v) => setState(() => _jpgQuality = v.round()),
          ),
        ],
        if (_format == ExportFormat.pdf || isImage)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include annotations'),
            value: _includeAnnotations,
            onChanged: running ? null : (v) => setState(() => _includeAnnotations = v),
          ),
        const SizedBox(height: Space.lg),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Text(_message!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
          ),
        if (running) ...[
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: Space.sm),
          Text('Converting… $_done of $_total', style: t.bodyMedium),
          const SizedBox(height: Space.sm),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTouchTarget)),
            onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
            child: Text(_cancelRequested ? 'Cancelling…' : 'Cancel'),
          ),
        ] else
          FilledButton.icon(
            key: const Key('export.start'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTouchTarget)),
            onPressed: _canExport ? _startExport : null,
            icon: const Icon(Icons.file_download_outlined),
            label: Text('Export as ${_formatLabel(_format)}'),
          ),
        if (_phase == _Phase.done && _result != null) ..._resultSection(context),
      ],
    );
  }

  List<Widget> _resultSection(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final files = _result!.files;
    final bytes = files.fold<int>(0, (s, f) {
      try {
        return s + File(f).lengthSync();
      } on FileSystemException {
        return s;
      }
    });
    return [
      const SizedBox(height: Space.lg),
      Text(files.length == 1 ? p.basename(files.single) : '${files.length} files',
          key: const Key('export.done'), style: t.titleMedium),
      for (final n in noticesOf(_result!))
        Padding(padding: const EdgeInsets.only(top: Space.xs), child: Text(n, style: t.bodySmall)),
      Text(_formatBytes(bytes), style: t.bodySmall),
      const SizedBox(height: Space.md),
      Row(children: [
        Expanded(
          child: FilledButton.tonalIcon(
            key: const Key('export.share'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTouchTarget)),
            onPressed: _share,
            icon: Icon(Icons.adaptive.share),
            label: const Text('Share'),
          ),
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTouchTarget)),
            onPressed: _saveAs,
            icon: const Icon(Icons.save_alt),
            label: const Text('Save to…'),
          ),
        ),
      ]),
      const SizedBox(height: Space.sm),
      Text('Exported files are removed from this app when you leave this screen.', style: t.bodySmall),
    ];
  }
}

String _formatLabel(ExportFormat f) => switch (f) {
      ExportFormat.pdf => 'PDF',
      ExportFormat.png => 'PNG',
      ExportFormat.jpg => 'JPG',
      ExportFormat.txt => 'Text (TXT)',
      ExportFormat.docx => 'Word (DOCX)',
    };

String _formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Bundles [files] into a zip at [dest] on a background isolate, streaming
/// one file at a time from disk (stored: images are already compressed).
Future<void> zipFiles(List<String> files, String dest) => Isolate.run(() {
      final enc = ZipFileEncoder()..create(dest, level: ZipFileEncoder.store);
      try {
        for (final f in files) {
          enc.addFileSync(File(f), p.basename(f), ZipFileEncoder.store);
        }
      } finally {
        enc.closeSync();
      }
    });

/// A dialog action that is Cupertino-styled on Apple platforms.
Widget adaptiveDialogAction(BuildContext context,
    {Key? key, required String label, required VoidCallback onPressed, bool isDefault = false}) {
  if (isCupertino(context)) {
    return CupertinoDialogAction(key: key, isDefaultAction: isDefault, onPressed: onPressed, child: Text(label));
  }
  return isDefault
      ? FilledButton(key: key, onPressed: onPressed, child: Text(label))
      : TextButton(key: key, onPressed: onPressed, child: Text(label));
}
