import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models/document_ref.dart';
import '../../core/pdf/document_service.dart';
import '../../core/pdf/page_editor.dart';
import '../../core/providers.dart';
import '../../core/security/limits.dart';
import '../../ui/design_system/adaptive.dart';
import '../../ui/design_system/tokens.dart';
import 'engine/pdfrx_page_editor.dart';
import 'engine/safe_open.dart';
import 'organize/organize_model.dart';
import 'organize/page_ranges.dart';

/// Opens a document for the organiser. Injectable for tests.
typedef OrganizeDocumentOpener = Future<PdfDocument> Function(DocumentRef ref);

/// Page organiser (route `/organize`): reorderable thumbnail grid (long-press
/// and drag), multi-select (tap), rotate, delete, extract, split, merge,
/// undo/redo, Save / Save as copy. The original file is only replaced after
/// an explicit confirmation, and only if it lives in app-private storage.
class OrganizeScreen extends ConsumerStatefulWidget {
  const OrganizeScreen({super.key, required this.document, this.opener});
  final DocumentRef document;
  final OrganizeDocumentOpener? opener;

  @override
  ConsumerState<OrganizeScreen> createState() => _OrganizeScreenState();
}

class _OrganizeScreenState extends ConsumerState<OrganizeScreen> {
  final OrganizeModel _model = OrganizeModel();
  final List<PdfDocument> _sources = [];
  final List<String> _sourceNames = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    for (final d in _sources) {
      unawaited(d.dispose());
    }
    _model.dispose();
    super.dispose();
  }

  Future<PdfDocument> _openRef(DocumentRef doc) {
    final opener = widget.opener;
    if (opener != null) return opener(doc);
    return openWithLimits(doc, service: _documentService());
  }

  /// The Viewer feature's service, or null while it is not wired.
  DocumentService? _documentService() {
    try {
      return ref.read(documentServiceProvider);
    } catch (_) {
      return null;
    }
  }

  Future<void> _open() async {
    try {
      final doc = await _openRef(widget.document);
      if (!mounted) {
        await doc.dispose();
        return;
      }
      setState(() {
        _sources
          ..clear()
          ..add(doc);
        _sourceNames
          ..clear()
          ..add(widget.document.displayName);
        _model.reset(sourceIndex: 0, pageCount: doc.pages.length);
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'This PDF could not be opened.';
        });
      }
    }
  }

  PdfrxPageEditor get _editor {
    try {
      final e = ref.read(pageEditorProvider);
      if (e is PdfrxPageEditor) return e;
    } catch (_) {}
    return PdfrxPageEditor();
  }

  List<PageSource> _toSources(List<OrganizeItem> items) => [
        for (final i in items) PageSource(_sources[i.sourceIndex], i.pageNumber, quarterTurns: i.quarterTurns),
      ];

  void _snack(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<T?> _run<T>(Future<T> Function() f, {String failure = 'Something went wrong'}) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      return await f();
    } catch (_) {
      _snack(failure);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  SnackBarAction _exportAction(String path, String name) => SnackBarAction(
        label: 'Export',
        onPressed: () async {
          try {
            await ref.read(filePickServiceProvider).saveAs(path, suggestedName: name);
          } catch (_) {
            _snack('Export is not available');
          }
        },
      );

  Future<String?> _saveCopy(List<OrganizeItem> items, String suffix) => _run(() async {
        final bytes = await _editor.compose(_toSources(items), base: _sources.first);
        final name = '${widget.document.baseName}$suffix.pdf';
        final path = await ref.read(saveServiceProvider).save(bytes, mode: SaveMode.saveAsCopy, suggestedName: name);
        return path;
      }, failure: 'Could not save the PDF');

  Future<void> _saveAsCopy() async {
    final path = await _saveCopy(_model.items, ' (edited)');
    if (path == null) return;
    _model.undoStack.markSaved();
    _snack('Saved a copy', action: _exportAction(path, '${widget.document.baseName} (edited).pdf'));
  }

  Future<void> _saveOverwrite() async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Replace the original?',
      message: 'The original file “${widget.document.displayName}” will be replaced with the '
          'reorganised pages. This cannot be undone. Choose “Save as copy” to keep the original.',
      confirmLabel: 'Replace',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    final path = await _run(() async {
      final bytes = await _editor.compose(_toSources(_model.items), base: _sources.first);
      return ref.read(saveServiceProvider).save(bytes,
          mode: SaveMode.overwriteOriginal,
          suggestedName: widget.document.displayName,
          originalPath: widget.document.path);
    }, failure: 'Could not save the PDF');
    if (path == null || !mounted) return;
    if (path != widget.document.path) {
      _model.undoStack.markSaved();
      _snack('The original can’t be replaced here, so a copy was saved instead',
          action: _exportAction(path, widget.document.displayName));
      return;
    }
    // Reload from the replaced file.
    final old = List.of(_sources);
    _sources.clear();
    _sourceNames.clear();
    for (final d in old) {
      await d.dispose();
    }
    setState(() => _loading = true);
    await _open();
    _snack('Saved');
  }

  Future<void> _extract() async {
    final items = _model.selectedItems;
    if (items.isEmpty) return;
    final label = items.every((i) => i.sourceIndex == 0)
        ? describePages([for (final i in items) i.pageNumber])
        : '${items.length}';
    final path = await _saveCopy(items, ' (pages $label)');
    if (path != null) _snack('Extracted ${items.length} page(s) to a new PDF', action: _exportAction(path, 'pages.pdf'));
  }

  Future<void> _split() async {
    final count = _model.items.length;
    final input = await showDialog<String>(context: context, builder: (_) => _SplitDialog(pageCount: count));
    if (input == null || !mounted) return;
    final List<List<int>> ranges;
    try {
      ranges = input.startsWith('every:')
          ? chunkPages(count, int.parse(input.substring(6)))
          : parsePageRanges(input, count);
    } on FormatException catch (e) {
      _snack(e.message);
      return;
    }
    final saved = await _run(() async {
      final out = <String>[];
      for (final r in ranges) {
        final items = [for (final n in r) _model.items[n - 1]];
        final bytes = await _editor.compose(_toSources(items), base: _sources.first);
        out.add(await ref.read(saveServiceProvider).save(bytes,
            mode: SaveMode.saveAsCopy, suggestedName: '${widget.document.baseName} (part ${describePages(r)}).pdf'));
      }
      return out;
    }, failure: 'Could not split the PDF');
    if (saved != null) _snack('Created ${saved.length} PDFs');
  }

  Future<void> _merge() async {
    List<String> paths;
    try {
      paths = await ref.read(filePickServiceProvider).pickPdfs(multiple: true);
    } catch (_) {
      _snack('Adding files is not available');
      return;
    }
    if (paths.isEmpty || !mounted) return;
    if (_sources.length + paths.length > SecurityLimits.maxMergeInputs) {
      _snack('You can combine at most ${SecurityLimits.maxMergeInputs} files');
      return;
    }
    await _run(() async {
      for (final path in paths) {
        PdfDocument doc;
        try {
          final service = _documentService();
          if (widget.opener == null && service != null) {
            final r = await service.importFile(path);
            doc = await service.open(r);
          } else {
            doc = await openPathWithLimits(path);
          }
        } catch (_) {
          _snack('One of the files could not be opened');
          continue;
        }
        if (_model.items.length + doc.pages.length > SecurityLimits.maxPages) {
          await doc.dispose();
          _snack('Too many pages');
          continue;
        }
        _sources.add(doc);
        _sourceNames.add(path.split(RegExp(r'[/\\]')).last);
        await _model.append(sourceIndex: _sources.length - 1, pageCount: doc.pages.length);
      }
    }, failure: 'Could not add the files');
  }

  Future<void> _delete() async {
    final ok = await _model.delete(_model.selected);
    if (!ok) _snack('A PDF needs at least one page');
  }

  Future<bool> _confirmDiscard() async {
    if (!_model.undoStack.isDirty || !_model.isModified) return true;
    final ok = await showAdaptiveConfirm(context,
        title: 'Discard changes?',
        message: 'Your page changes have not been saved.',
        confirmLabel: 'Discard',
        destructive: true);
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_model, _model.undoStack]),
      builder: (context, _) {
        final undo = _model.undoStack;
        final hasSel = _model.selected.isNotEmpty;
        return PopScope(
          canPop: !undo.isDirty || !_model.isModified,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final nav = Navigator.of(context);
            if (await _confirmDiscard() && mounted) nav.pop();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(hasSel ? '${_model.selected.length} selected' : 'Organize pages'),
              leading: hasSel
                  ? IconButton(
                      tooltip: 'Clear selection', icon: const Icon(Icons.close), onPressed: _model.clearSelection)
                  : null,
              actions: [
                IconButton(
                    key: const ValueKey('organize-undo'),
                    tooltip: 'Undo',
                    onPressed: undo.canUndo && !_busy ? () => unawaited(undo.undo()) : null,
                    icon: const Icon(Icons.undo)),
                IconButton(
                    key: const ValueKey('organize-redo'),
                    tooltip: 'Redo',
                    onPressed: undo.canRedo && !_busy ? () => unawaited(undo.redo()) : null,
                    icon: const Icon(Icons.redo)),
                PopupMenuButton<String>(
                  key: const ValueKey('organize-menu'),
                  enabled: !_loading && _error == null && !_busy,
                  onSelected: (v) => unawaited(switch (v) {
                    'copy' => _saveAsCopy(),
                    'overwrite' => _saveOverwrite(),
                    'merge' => _merge(),
                    'split' => _split(),
                    'all' => Future.sync(_model.selectAll),
                    _ => Future.value(),
                  }),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'copy', child: Text('Save as copy')),
                    PopupMenuItem(value: 'overwrite', child: Text('Save (replace original)…')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'merge', child: Text('Add PDFs…')),
                    PopupMenuItem(value: 'split', child: Text('Split…')),
                    PopupMenuItem(value: 'all', child: Text('Select all')),
                  ],
                ),
              ],
              bottom: _busy
                  ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
                  : null,
            ),
            body: _body(context),
            bottomNavigationBar: hasSel ? _selectionBar(context) : null,
          ),
        );
      },
    );
  }

  Widget _selectionBar(BuildContext context) => BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
                key: const ValueKey('organize-rotate-left'),
                tooltip: 'Rotate left',
                onPressed: _busy ? null : () => unawaited(_model.rotate(_model.selected, -1)),
                icon: const Icon(Icons.rotate_left)),
            IconButton(
                key: const ValueKey('organize-rotate-right'),
                tooltip: 'Rotate right',
                onPressed: _busy ? null : () => unawaited(_model.rotate(_model.selected, 1)),
                icon: const Icon(Icons.rotate_right)),
            IconButton(
                key: const ValueKey('organize-delete'),
                tooltip: 'Delete pages',
                onPressed: _busy ? null : () => unawaited(_delete()),
                icon: const Icon(Icons.delete_outline)),
            IconButton(
                key: const ValueKey('organize-extract'),
                tooltip: 'Extract to new PDF',
                onPressed: _busy ? null : () => unawaited(_extract()),
                icon: const Icon(Icons.file_copy_outlined)),
          ],
        ),
      );

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    final items = _model.items;
    return GridView.builder(
      padding: const EdgeInsets.all(Space.md),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170,
        mainAxisSpacing: Space.md,
        crossAxisSpacing: Space.md,
        childAspectRatio: 0.72,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final cell = _PageCell(
          key: ValueKey('page-cell-${item.id}'),
          document: _sources[item.sourceIndex],
          item: item,
          index: index,
          sourceLabel: item.sourceIndex == 0 ? null : _sourceNames[item.sourceIndex],
          selected: _model.isSelected(item.id),
          onTap: () => _model.toggleSelected(item.id),
        );
        return DragTarget<int>(
          onWillAcceptWithDetails: (d) => d.data != index,
          onAcceptWithDetails: (d) => unawaited(_model.move(d.data, index)),
          builder: (context, candidates, _) => AnimatedContainer(
            duration: Motion.of(context, Motion.fast),
            decoration: BoxDecoration(
              borderRadius: Radii.card,
              border: Border.all(
                width: 2,
                color: candidates.isNotEmpty ? Theme.of(context).colorScheme.primary : Colors.transparent,
              ),
            ),
            child: LongPressDraggable<int>(
              data: index,
              feedback: Material(
                elevation: 6,
                borderRadius: Radii.card,
                child: SizedBox(width: 120, height: 160, child: cell),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: cell),
              child: cell,
            ),
          ),
        );
      },
    );
  }
}

class _PageCell extends StatelessWidget {
  const _PageCell({
    super.key,
    required this.document,
    required this.item,
    required this.index,
    required this.selected,
    required this.onTap,
    this.sourceLabel,
  });
  final PdfDocument document;
  final OrganizeItem item;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final String? sourceLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = document.pages[item.pageNumber - 1];
    final rotation = PdfPageRotation.values[(page.rotation.index + item.quarterTurns) & 3];
    return Semantics(
      label: 'Page ${index + 1}${selected ? ', selected' : ''}',
      button: true,
      child: InkWell(
        borderRadius: Radii.card,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Space.xs),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PdfPageView(
                      document: document,
                      pageNumber: item.pageNumber,
                      rotationOverride: rotation,
                      maximumDpi: 72,
                    ),
                    if (selected)
                      Container(
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.18),
                          border: Border.all(color: scheme.primary, width: 2),
                        ),
                      ),
                    Positioned(
                      top: Space.xs,
                      right: Space.xs,
                      child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: selected ? scheme.primary : scheme.outline),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.xs),
              Text(
                sourceLabel == null ? '${index + 1}' : '${index + 1} · $sourceLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.pageCount});
  final int pageCount;
  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  final _ranges = TextEditingController();
  final _every = TextEditingController(text: '1');
  bool _byRanges = true;
  String? _error;

  @override
  void dispose() {
    _ranges.dispose();
    _every.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      if (_byRanges) {
        parsePageRanges(_ranges.text, widget.pageCount);
        Navigator.pop(context, _ranges.text);
      } else {
        final n = int.tryParse(_every.text.trim()) ?? 0;
        chunkPages(widget.pageCount, n);
        Navigator.pop(context, 'every:$n');
      }
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Split PDF'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('By ranges')),
                ButtonSegment(value: false, label: Text('Every N pages')),
              ],
              selected: {_byRanges},
              onSelectionChanged: (s) => setState(() {
                _byRanges = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: Space.md),
            if (_byRanges)
              TextField(
                key: const ValueKey('split-ranges'),
                controller: _ranges,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Ranges',
                  hintText: 'e.g. 1-3, 4-${widget.pageCount}',
                  helperText: 'Each range becomes a separate PDF',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              )
            else
              TextField(
                controller: _every,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Pages per file',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: const Text('Split')),
        ],
      );
}
