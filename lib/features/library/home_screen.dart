import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app_router.dart';
import '../../core/models/document_ref.dart';
import '../../ui/design_system/design_system.dart';
import 'open_document.dart';
import 'recents_controller.dart';

/// Library / home: recent files, search, open and merge entry points.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openPdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final docs = await pickAndImport(context, ref);
      if (docs == null || docs.isEmpty || !mounted) return;
      await openInViewer(context, ref, docs.first);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _merge() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final docs = await pickAndImport(context, ref, multiple: true);
      if (docs == null || docs.isEmpty || !mounted) return;
      if (docs.length < 2) {
        showAppSnackBar(context, 'Choose at least two PDFs to merge.');
        return;
      }
      await startMergeFlow(context, docs);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(RecentEntry e, int index) async {
    await ref.read(recentsProvider.notifier).remove(e.doc.id);
    if (!mounted) return;
    showAppSnackBar(
      context,
      'Removed “${e.doc.displayName}” from recents',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => ref.read(recentsProvider.notifier).restore(e, index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recents = ref.watch(recentsProvider);
    final all = recents.value ?? const <RecentEntry>[];
    final shown = filterRecents(all, _query);
    final wide = windowSizeOf(context) != WindowSize.compact;

    final List<Widget> slivers;
    if (recents.isLoading && !recents.hasValue) {
      slivers = [
        const SliverFillOrFit(child: AdaptiveProgress(size: 28)),
      ];
    } else if (all.isEmpty) {
      slivers = [
        SliverFillOrFit(
          child: FadeSlideIn(
            child: EmptyState(
              icon: Icons.picture_as_pdf_outlined,
              illustration: const AppLogo(size: 104),
              title: 'Your library is empty',
              message: 'Open a PDF from your device to start reading. '
                  'Everything stays on this device — no account, no cloud.',
              action: PrimaryButton(
                label: 'Open PDF',
                icon: Icons.file_open_outlined,
                busy: _busy,
                onPressed: _openPdf,
                semanticHint: 'Choose a PDF file from your device',
              ),
            ),
          ),
        ),
      ];
    } else {
      slivers = [
        SliverToBoxAdapter(child: _SearchField(controller: _search, onChanged: (q) => setState(() => _query = q))),
        SliverToBoxAdapter(
          child: SectionHeader(
            _query.isEmpty ? 'Recent' : 'Results',
            trailing: Text(
              '${shown.length}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              semanticsLabel: '${shown.length} documents',
            ),
          ),
        ),
        if (shown.isEmpty)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No matches',
              message: 'No recent file names contain “${_query.trim()}”.',
            ),
          )
        else if (wide)
          SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 230,
              mainAxisExtent: DocumentCard.extentFor(context),
              mainAxisSpacing: Space.md,
              crossAxisSpacing: Space.md,
            ),
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final e = shown[i];
              return FadeSlideIn.staggered(
                key: ValueKey('card-${e.doc.id}'),
                index: i,
                child: DocumentCard(
                  data: e.tileData,
                  onTap: () => openInViewer(context, ref, e.doc),
                  trailing: _ItemMenu(entry: e, onRemove: () => _remove(e, all.indexOf(e))),
                ),
              );
            },
          )
        else
          SliverList.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final e = shown[i];
              return FadeSlideIn.staggered(
                key: ValueKey('tile-${e.doc.id}'),
                index: i,
                child: Dismissible(
                  key: ValueKey('dismiss-${e.doc.id}'),
                  direction: DismissDirection.endToStart,
                  background: const _DismissBackground(),
                  onDismissed: (_) => _remove(e, all.indexOf(e)),
                  child: DocumentTile(
                    data: e.tileData,
                    onTap: () => openInViewer(context, ref, e.doc),
                    trailing: _ItemMenu(entry: e, onRemove: () => _remove(e, all.indexOf(e))),
                  ),
                ),
              );
            },
          ),
      ];
    }

    return AppScaffold(
      title: 'Library',
      maxContentWidth: wide ? 1200 : kMaxContentWidth,
      actions: [
        IconButton(
          tooltip: 'Merge PDFs',
          icon: const Icon(Icons.merge_type_rounded),
          onPressed: _busy ? null : _merge,
        ),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(isCupertino(context) ? CupertinoIcons.settings : Icons.settings_outlined),
          onPressed: () => context.push(Routes.settings),
        ),
        const SizedBox(width: Space.xs),
      ],
      floatingActionButton: all.isEmpty
          ? null
          : Semantics(
              hint: 'Choose a PDF file from your device',
              child: FloatingActionButton.extended(
                onPressed: _busy ? null : _openPdf,
                tooltip: 'Open a PDF',
                icon: _busy
                    ? AdaptiveProgress(size: 20, color: Theme.of(context).colorScheme.onPrimary)
                    : const Icon(Icons.add_rounded),
                label: const Text('Open PDF'),
              ),
            ),
      slivers: slivers,
    );
  }
}

/// Merge entry point.
///
/// TODO(lead): OrganizeScreen currently takes a single DocumentRef via
/// `extra`. Once the Editing agent exposes a merge flow that accepts several
/// documents (e.g. `extra: List<DocumentRef>` or a dedicated route), pass the
/// whole [docs] list here. Until then we open the first document in the
/// organize flow so the user lands in the page tools.
Future<void> startMergeFlow(BuildContext context, List<DocumentRef> docs) async {
  await context.push(Routes.organize, extra: docs.first);
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final field = isCupertino(context)
        ? CupertinoSearchTextField(
            controller: controller,
            onChanged: onChanged,
            placeholder: 'Search recent files',
            padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm + 4),
          )
        : SearchBar(
            controller: controller,
            onChanged: onChanged,
            hintText: 'Search recent files',
            leading: const Icon(Icons.search_rounded),
            trailing: [
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => controller.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
              ),
            ],
          );
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs, bottom: Space.xs),
      child: Semantics(textField: true, label: 'Search recent files', child: field),
    );
  }
}

class _ItemMenu extends StatelessWidget {
  const _ItemMenu({required this.entry, required this.onRemove});
  final RecentEntry entry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'More options for ${entry.doc.displayName}',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (v) {
          if (v == 'remove') onRemove();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'remove',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.playlist_remove_rounded),
              title: Text('Remove from recents'),
            ),
          ),
        ],
      );
}

class _DismissBackground extends StatelessWidget {
  const _DismissBackground();
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      alignment: AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      decoration: BoxDecoration(color: s.errorContainer, borderRadius: Radii.card),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              'Remove',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: s.onErrorContainer, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: Space.sm),
          Icon(Icons.delete_outline_rounded, color: s.onErrorContainer),
        ],
      ),
    );
  }
}
