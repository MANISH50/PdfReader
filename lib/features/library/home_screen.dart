import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app_router.dart';
import '../../core/models/document_ref.dart';
import '../../ui/design_system/design_system.dart';
import '../onboarding/default_app_guide_view.dart' show showDefaultAppGuideSheet;
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
  RecentFilter _filter = RecentFilter.all;
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
      final docs = await pickAndImport(context, ref, anyDocument: true);
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
      action: SnackBarAction(label: 'Undo', onPressed: () => ref.read(recentsProvider.notifier).restore(e, index)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recents = ref.watch(recentsProvider);
    final all = recents.value ?? const <RecentEntry>[];
    final shown = filterRecents(all, _query, filter: _filter);
    final wide = windowSizeOf(context) != WindowSize.compact;
    final t = Theme.of(context);
    final gutter = contentGutter(context, maxWidth: wide ? 1200 : kMaxContentWidth);
    // Short windows (landscape phones) and big text: a slimmer header with
    // the quick actions as icons, so documents stay in view.
    final compact = MediaQuery.sizeOf(context).height < 600 || MediaQuery.textScalerOf(context).scale(10) > 15;

    final List<Widget> slivers;
    if (recents.isLoading && !recents.hasValue) {
      slivers = [
        // Static (not a spinner): loading is near-instant, and an endless
        // animation would also keep widget tests from settling.
        const SliverFillOrFit(child: SizedBox.shrink()),
      ];
    } else if (all.isEmpty) {
      slivers = [
        SliverFillOrFit(
          child: FadeSlideIn(
            child: EmptyState(
              icon: Icons.picture_as_pdf_outlined,
              illustration: const AppLogo(size: 112),
              title: 'Your library is empty',
              message:
                  'Open a PDF, Word, Excel, CSV, Markdown or text file from your device to start reading. '
                  'Everything stays on this device — no account, no cloud.',
              action: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PrimaryButton(
                    key: const Key('home.open'),
                    label: 'Open file',
                    icon: Icons.file_open_outlined,
                    busy: _busy,
                    onPressed: _openPdf,
                    semanticHint: 'Choose a PDF, Word, Excel, CSV, Markdown or text file from your device',
                  ),
                  const SizedBox(height: Space.lg),
                  const _Highlights(),
                ],
              ),
            ),
          ),
        ),
      ];
    } else {
      slivers = [
        if (!compact)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: Space.md),
              child: Row(
                children: [
                  Expanded(
                    child: QuickAction(
                      icon: Icons.file_open_rounded,
                      label: 'Open',
                      tooltip: 'Open a file',
                      color: Brand.gradientColors[0],
                      onTap: _busy ? null : _openPdf,
                    ),
                  ),
                  Expanded(
                    child: QuickAction(
                      icon: Icons.merge_type_rounded,
                      label: 'Merge',
                      tooltip: 'Merge PDFs',
                      color: Brand.gradientColors[2],
                      onTap: _busy ? null : _merge,
                    ),
                  ),
                  Expanded(
                    child: QuickAction(
                      icon: Icons.verified_rounded,
                      label: 'Set default',
                      tooltip: 'Make PdfReader your default app',
                      color: Brand.gradientColors[1],
                      onTap: () => showDefaultAppGuideSheet(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              itemCount: RecentFilter.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
              itemBuilder: (context, i) {
                final f = RecentFilter.values[i];
                final on = f == _filter;
                final color = f == RecentFilter.all ? Brand.gradientColors[0] : FileTypeStyle.color(f.badge);
                return ChoiceChip(
                  key: Key('home.filter.${f.name}'),
                  label: Text(f.label),
                  selected: on,
                  showCheckmark: false,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  avatar: f == RecentFilter.all
                      ? null
                      : Icon(FileTypeStyle.icon(f.badge), size: 18, color: on ? Colors.white : color),
                  selectedColor: color,
                  labelStyle: t.textTheme.labelLarge?.copyWith(color: on ? Colors.white : null),
                  side: on ? BorderSide(color: color) : null,
                  onSelected: (_) => setState(() => _filter = f),
                );
              },
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SectionHeader(
            _query.isEmpty && _filter == RecentFilter.all ? 'Recent' : 'Results',
            trailing: Text(
              '${shown.length}',
              style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              semanticsLabel: '${shown.length} documents',
            ),
          ),
        ),
        if (shown.isEmpty)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No matches',
              message: _query.trim().isEmpty
                  ? 'No recent ${_filter.label} files.'
                  : 'No recent file names contain “${_query.trim()}”.',
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
                  key: Key('home.recent.$i'),
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
                    key: Key('home.recent.$i'),
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

    return Scaffold(
      key: const Key('home.screen'),
      floatingActionButton: all.isEmpty
          ? null
          : Semantics(
              hint: 'Choose a PDF, Word, Excel, CSV, Markdown or text file from your device',
              child: GradientFab(
                key: const Key('home.open'),
                onPressed: _busy ? null : _openPdf,
                tooltip: 'Open a file',
                icon: _busy ? const AdaptiveProgress(size: 20, color: Colors.white) : const Icon(Icons.add_rounded),
                label: const Text('Open file'),
              ),
            ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _Header(
              compact: compact,
              actions: compact && all.isNotEmpty
                  ? [
                      IconButton(
                        tooltip: 'Merge PDFs',
                        icon: const Icon(Icons.merge_type_rounded),
                        onPressed: _busy ? null : _merge,
                      ),
                      IconButton(
                        tooltip: 'Make PdfReader your default app',
                        icon: const Icon(Icons.verified_outlined),
                        onPressed: () => showDefaultAppGuideSheet(context),
                      ),
                    ]
                  : const [],
              count: all.length,
              search: all.isEmpty
                  ? null
                  : _SearchField(controller: _search, onChanged: (q) => setState(() => _query = q)),
              gutter: gutter,
            ),
          ),
          for (final s in slivers)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              sliver: s,
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: Space.xxl + Space.xxl)),
        ],
      ),
    );
  }
}

String _greeting(DateTime now) {
  final h = now.hour;
  if (h < 5) return 'Good night';
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

class _Header extends StatelessWidget {
  const _Header({
    required this.count,
    required this.search,
    required this.gutter,
    this.compact = false,
    this.actions = const [],
  });
  final int count;
  final bool compact;
  final List<Widget> actions;
  final Widget? search;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const white70 = Colors.white; // full white keeps ≥ 4.5:1 across the gradient
    return GradientHeader(
      bottomPadding: search == null ? Space.lg : Space.lg,
      child: Padding(
        padding: EdgeInsets.fromLTRB(gutter, Space.sm, gutter - Space.sm, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const AppLogo(size: 36),
                const SizedBox(width: Space.sm + 2),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'PdfReader',
                      style: t.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                ...actions,
                IconButton(
                  key: const Key('home.settings'),
                  tooltip: 'Settings',
                  color: Colors.white,
                  icon: Icon(isCupertino(context) ? CupertinoIcons.settings : Icons.settings_outlined),
                  onPressed: () => context.push(Routes.settings),
                ),
              ],
            ),
            if (!compact) ...[
              const SizedBox(height: Space.lg),
              Text(
                _greeting(DateTime.now()),
                style: t.textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: Space.xxs),
              Text(
                count == 0
                    ? 'Private, offline reading for all your files'
                    : '$count ${count == 1 ? 'document' : 'documents'} · offline & private',
                style: t.textTheme.bodyMedium?.copyWith(color: white70),
              ),
            ],
            if (search != null) ...[
              const SizedBox(height: Space.md),
              Padding(
                padding: const EdgeInsets.only(right: Space.sm),
                child: search!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Highlights extends StatelessWidget {
  const _Highlights();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget item(IconData icon, String label, Color c) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBadge(icon, color: c, size: 40),
          const SizedBox(height: Space.xs),
          Text(label, style: t.textTheme.labelMedium),
        ],
      ),
    );
    return Wrap(
      alignment: WrapAlignment.center,
      runSpacing: Space.sm,
      children: [
        item(Icons.wifi_off_rounded, 'Offline', Brand.gradientColors[0]),
        item(Icons.lock_rounded, 'Private', Brand.gradientColors[1]),
        item(Icons.block_rounded, 'No ads', Brand.gradientColors[2]),
      ],
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
            backgroundColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.surface),
            elevation: const WidgetStatePropertyAll(2),
            side: const WidgetStatePropertyAll(BorderSide.none),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            onChanged: onChanged,
            hintText: 'Search recent files',
            leading: Icon(Icons.search_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
            trailing: [
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => controller.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: Icon(Icons.close_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
