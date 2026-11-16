import 'package:go_router/go_router.dart';

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
      // Never show an error page: unknown locations (e.g. a content:// URI the
      // OS hands over when PdfReader is the default PDF app) and document
      // routes without a document go to Home. Incoming files are opened by
      // IncomingFileListener, not by URL routing.
      redirect: (_, s) => routeRedirect(s.uri.path, s.extra, showOnboarding: showOnboarding),
      errorBuilder: (_, _) => const HomeScreen(),
    );

const _docRoutes = {Routes.viewer, Routes.organize, Routes.export};
const _knownRoutes = {Routes.home, Routes.onboarding, Routes.settings, ..._docRoutes};

/// Returns where to go instead, or null to allow [path].
String? routeRedirect(String path, Object? extra, {bool showOnboarding = false}) {
  final fallback = showOnboarding ? Routes.onboarding : Routes.home;
  if (!_knownRoutes.contains(path)) return fallback;
  if (_docRoutes.contains(path) && extra is! DocumentRef) return fallback;
  return null;
}
