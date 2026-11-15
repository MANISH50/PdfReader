import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'app_router.dart';
import 'core/models/app_settings.dart';
import 'core/providers.dart';
import 'ui/design_system/app_theme.dart';

class PdfReaderApp extends ConsumerStatefulWidget {
  const PdfReaderApp({super.key, required this.showOnboarding});
  final bool showOnboarding;

  @override
  ConsumerState<PdfReaderApp> createState() => _PdfReaderAppState();
}

class _PdfReaderAppState extends ConsumerState<PdfReaderApp> {
  late final GoRouter _router = buildRouter(showOnboarding: widget.showOnboarding);

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    return MaterialApp.router(
      title: 'PdfReader',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: switch (settings.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      routerConfig: _router,
    );
  }
}
