import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/app_settings.dart';
import '../../core/models/reading_state.dart';
import '../../core/providers.dart';
import '../../ui/app_info.dart';
import '../../ui/design_system/design_system.dart';
import '../library/recents_controller.dart';
import '../onboarding/default_app_guide_view.dart';

String pageThemeLabel(PageTheme t) => switch (t) {
      PageTheme.light => 'Light',
      PageTheme.dark => 'Dark',
      PageTheme.sepia => 'Sepia',
      PageTheme.night => 'Night',
    };

String readingModeLabel(ReadingMode m) => switch (m) {
      ReadingMode.continuous => 'Continuous scroll',
      ReadingMode.singlePage => 'Single page',
      ReadingMode.twoPage => 'Two-page spread',
      ReadingMode.reflow => 'Text view (reflow)',
    };

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _change(WidgetRef ref, AppSettings Function(AppSettings) f) =>
      ref.read(settingsProvider.notifier).change(f);

  Future<void> _clearRecents(BuildContext context, WidgetRef ref) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Clear recent files?',
      message: 'The list of recent files will be emptied. Your PDFs themselves are not deleted.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (ok != true) return;
    try {
      await ref.read(recentsProvider.notifier).clearAll();
      if (context.mounted) showAppSnackBar(context, 'Recent files cleared');
    } catch (_) {
      if (context.mounted) showAppSnackBar(context, 'Couldn’t clear recent files.');
    }
  }

  Future<void> _clearTemp(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(tempFilesProvider).wipe();
      if (context.mounted) showAppSnackBar(context, 'Temporary files cleared');
    } catch (_) {
      if (context.mounted) showAppSnackBar(context, 'Couldn’t clear temporary files.');
    }
  }

  Future<void> _pickReadingMode(BuildContext context, WidgetRef ref, ReadingMode current) async {
    final picked = await showAppBottomSheet<ReadingMode>(
      context,
      title: 'Default reading mode',
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in ReadingMode.values)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
              selected: m == current,
              title: Text(readingModeLabel(m)),
              trailing: m == current ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(c, m),
            ),
        ],
      ),
    );
    if (picked != null) await _change(ref, (s) => s.copyWith(defaultReadingMode: picked));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final t = Theme.of(context);

    return AppScaffold(
      title: 'Settings',
      gradientHeader: true,
      subtitle: 'Offline · No ads · No tracking',
      slivers: [
        SliverList.list(children: [
          const SectionHeader('Appearance'),
          _Group(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.xs),
              child: Text('App theme', style: t.textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, Space.md),
              child: AdaptiveSegmented<AppThemeMode>(
                semanticLabel: 'App theme',
                selected: settings.themeMode,
                onChanged: (v) => _change(ref, (s) => s.copyWith(themeMode: v)),
                segments: const [
                  Segment(AppThemeMode.system, 'System', key: Key('settings.theme.system')),
                  Segment(AppThemeMode.light, 'Light', key: Key('settings.theme.light')),
                  Segment(AppThemeMode.dark, 'Dark', key: Key('settings.theme.dark')),
                ],
              ),
            ),
          ]),
          const SectionHeader('Reading'),
          _Group(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.sm),
              child: Text('Default page theme', style: t.textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
              child: _PageThemePicker(
                selected: settings.defaultPageTheme,
                onChanged: (v) => _change(ref, (s) => s.copyWith(defaultPageTheme: v)),
              ),
            ),
            const Divider(indent: Space.md, endIndent: Space.md),
            ListTile(
              leading: const IconBadge(Icons.view_agenda_outlined, color: Color(0xFF3B82F6)),
              title: const Text('Default reading mode'),
              subtitle: Text(readingModeLabel(settings.defaultReadingMode)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _pickReadingMode(context, ref, settings.defaultReadingMode),
            ),
            MergeSemantics(
              child: ListTile(
                leading: const IconBadge(Icons.light_mode_outlined, color: Color(0xFFF59E0B)),
                title: const Text('Keep screen on'),
                subtitle: const Text('While a document is open'),
                trailing: AdaptiveSwitch(
                  value: settings.keepScreenOn,
                  onChanged: (v) => _change(ref, (s) => s.copyWith(keepScreenOn: v)),
                ),
                onTap: () => _change(ref, (s) => s.copyWith(keepScreenOn: !s.keepScreenOn)),
              ),
            ),
            _TextSizeTile(
              value: settings.textScale,
              onChanged: (v) => _change(ref, (s) => s.copyWith(textScale: v)),
            ),
          ]),
          const SectionHeader('Opening PDFs'),
          _Group(children: [
            ListTile(
              leading: const IconBadge(Icons.open_in_new_rounded, color: Color(0xFF7C3AED)),
              title: const Text('How to open PDFs with PdfReader'),
              subtitle: const Text('Make it your PDF app'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showDefaultAppGuideSheet(context),
            ),
          ]),
          const SectionHeader('Storage'),
          _Group(children: [
            ListTile(
              leading: const IconBadge(Icons.history_rounded, color: Color(0xFF0D9488)),
              title: const Text('Clear recent files'),
              subtitle: const Text('Your PDFs are not deleted'),
              onTap: () => _clearRecents(context, ref),
            ),
            ListTile(
              leading: const IconBadge(Icons.cleaning_services_outlined, color: Color(0xFFDB2777)),
              title: const Text('Clear temporary files'),
              subtitle: const Text('Scratch files from exports and sharing'),
              onTap: () => _clearTemp(context, ref),
            ),
          ]),
          const SectionHeader('Privacy'),
          const _PrivacyCard(),
          const SectionHeader('About'),
          _Group(children: [
            const ListTile(
              leading: AppLogo(size: 40),
              title: Text(AppInfo.name),
              subtitle: Text('Version ${AppInfo.version} (${AppInfo.build})'),
            ),
            ListTile(
              leading: const IconBadge(Icons.description_outlined, color: Color(0xFF64748B)),
              title: const Text('Open-source licenses'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: AppInfo.version,
                applicationLegalese: AppInfo.tagline,
                applicationIcon: const Padding(
                  padding: EdgeInsets.all(Space.md),
                  child: AppLogo(size: 64),
                ),
              ),
            ),
          ]),
        ]),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );
}

/// Four live-preview swatches: a mini page rendered through the real
/// [ReadingThemeSpec] colour filter on its background.
class _PageThemePicker extends StatelessWidget {
  const _PageThemePicker({required this.selected, required this.onChanged});
  final PageTheme selected;
  final ValueChanged<PageTheme> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        const gap = Space.sm;
        final perRow = c.maxWidth >= 4 * 72 + 3 * gap ? 4 : 2;
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final th in PageTheme.values)
              SizedBox(
                width: w,
                child: _Swatch(theme: th, selected: th == selected, onTap: () => onChanged(th)),
              ),
          ],
        );
      });
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.theme, required this.selected, required this.onTap});
  final PageTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final spec = ReadingThemeSpec.of(theme);
    Widget page = Container(
      margin: const EdgeInsets.fromLTRB(Space.md, Space.sm + 2, Space.md, 0),
      padding: const EdgeInsets.all(Space.sm),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xs)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 5, width: 28, color: const Color(0xFF1B1B1F)),
          const SizedBox(height: 5),
          for (final f in const [1.0, 0.9, 1.0, 0.6])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: FractionallySizedBox(
                widthFactor: f,
                child: Container(height: 3, color: const Color(0xFF5F6066)),
              ),
            ),
          Container(height: 8, width: 18, color: const Color(0xFFD9473F)),
        ],
      ),
    );
    if (spec.filter != null) page = ColorFiltered(colorFilter: spec.filter!, child: page);
    return Semantics(
      button: true,
      selected: selected,
      label: '${pageThemeLabel(theme)} page theme',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: Radii.card,
          onTap: onTap,
          child: Column(
            children: [
              AnimatedContainer(
                duration: Motion.of(context, Motion.fast),
                height: 84,
                decoration: BoxDecoration(
                  color: spec.background,
                  borderRadius: Radii.card,
                  border: Border.all(
                    color: selected ? s.primary : s.outlineVariant,
                    width: selected ? 2.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: page,
              ),
              const SizedBox(height: Space.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (selected) ...[
                    Icon(Icons.check_circle_rounded, size: 16, color: s.primary),
                    const SizedBox(width: Space.xs),
                  ],
                  Flexible(
                    child: Text(
                      pageThemeLabel(theme),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.labelLarge?.copyWith(color: selected ? s.primary : s.onSurface),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.xs),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextSizeTile extends StatefulWidget {
  const _TextSizeTile({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_TextSizeTile> createState() => _TextSizeTileState();
}

class _TextSizeTileState extends State<_TextSizeTile> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = (_drag ?? widget.value).clamp(0.8, 2.0);
    final pct = '${(v * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.format_size_rounded, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: Space.md),
            Expanded(child: Text('Reading text size', style: t.listTileTheme.titleTextStyle)),
            Text(pct, style: t.textTheme.labelLarge),
          ]),
          Text(
            'Used by the text view (reflow).',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          Slider.adaptive(
            value: v,
            min: 0.8,
            max: 2.0,
            divisions: 12,
            label: pct,
            semanticFormatterCallback: (x) => '${(x * 100).round()} percent',
            onChanged: (x) => setState(() => _drag = x),
            onChangeEnd: (x) {
              widget.onChanged(x);
              setState(() => _drag = null);
            },
          ),
          ExcludeSemantics(
            child: Text(
              'The quick brown fox reads in comfort.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodyLarge?.copyWith(fontSize: 16 * v),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    const items = [
      (Icons.wifi_off_rounded, 'No internet permission', 'PdfReader cannot connect to the internet at all.'),
      (Icons.analytics_outlined, 'No analytics or tracking', 'No usage data, crash reports or ads.'),
      (Icons.phonelink_lock_rounded, 'Files never leave this device', 'Only you decide what to share.'),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.lg - 4)),
        gradient: Brand.gradient(s.brightness),
        boxShadow: softShadow(s),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          children: [
            for (final (icon, title, body) in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: MergeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(Space.xs + 2),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                        child: Icon(icon, color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: t.textTheme.titleSmall?.copyWith(color: Colors.white)),
                            Text(body, style: t.textTheme.bodyMedium?.copyWith(color: Colors.white)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
