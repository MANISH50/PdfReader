import 'package:flutter/widgets.dart';

/// Widget keys the integration tests rely on. Feature code must attach these
/// exact keys (see TESTING.md, "Widget keys"). If a screen uses a different
/// structure, update this file and TESTING.md together.
abstract final class QaKeys {
  // Onboarding
  static const onboardingNext = Key('onboarding.next');
  static const onboardingDone = Key('onboarding.done');

  // Home / library
  static const homeScreen = Key('home.screen');
  static const homeOpen = Key('home.open'); // opens the system picker (FilePickService.pickPdfs)
  static const homeSettings = Key('home.settings');
  static Key homeRecent(int i) => Key('home.recent.$i');

  // Viewer
  static const viewerScreen = Key('viewer.screen');
  static const viewerScroll = Key('viewer.scroll'); // the scrollable holding the pages
  static Key viewerPage(int n) => Key('viewer.page.$n'); // 1-based
  static const viewerPageIndicator = Key('viewer.pageIndicator'); // Text "N / M"
  static const viewerGoToPage = Key('viewer.goToPage');
  static const viewerGoToPageField = Key('viewer.goToPage.field');
  static const viewerGoToPageOk = Key('viewer.goToPage.ok');
  static const viewerSearch = Key('viewer.search');
  static const viewerSearchField = Key('viewer.search.field');
  static const viewerSearchCount = Key('viewer.search.count'); // Text "i of n"
  static const viewerSearchNext = Key('viewer.search.next');
  static const viewerMenu = Key('viewer.menu');
  static const viewerExport = Key('viewer.export'); // menu item -> /export

  // Settings
  static const settingsThemeLight = Key('settings.theme.light');
  static const settingsThemeDark = Key('settings.theme.dark');
  static const settingsThemeSystem = Key('settings.theme.system');

  // Export
  static Key exportFormat(String ext) => Key('export.format.$ext'); // pdf, png, jpg, txt, docx
  static const exportStart = Key('export.start');
  static const exportConfirmLossy = Key('export.confirmLossy'); // "layout may change" warning
  static const exportShare = Key('export.share'); // result: share via ShareService
  static const exportDone = Key('export.done');

  // Password dialog
  static const passwordField = Key('password.field');
  static const passwordOk = Key('password.ok');
}
