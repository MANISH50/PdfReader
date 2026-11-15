import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'core/models/document_ref.dart';
import 'features/editor/organize_screen.dart';
import 'features/export/export_screen.dart';
import 'features/library/home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/viewer/viewer_screen.dart';

/// Route table. Screens that act on a document receive it via `extra`.
abstract final class Routes {
  static const home = '/';
  static const onboarding = '/onboarding';
  static const settings = '/settings';
  static const viewer = '/viewer';
  static const organize = '/organize';
  static const export = '/export';
}

GoRouter buildRouter({required bool showOnboarding}) => GoRouter(
      initialLocation: showOnboarding ? Routes.onboarding : Routes.home,
      routes: [
        GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
        GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingScreen()),
        GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
        GoRoute(
          path: Routes.viewer,
          builder: (_, s) => ViewerScreen(document: s.extra! as DocumentRef),
        ),
        GoRoute(
          path: Routes.organize,
          builder: (_, s) => OrganizeScreen(document: s.extra! as DocumentRef),
        ),
        GoRoute(
          path: Routes.export,
          builder: (_, s) => ExportScreen(document: s.extra! as DocumentRef),
        ),
      ],
      errorBuilder: (_, _) => const Scaffold(body: Center(child: Text('Page not found'))),
    );
