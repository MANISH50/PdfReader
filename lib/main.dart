import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'core/models/app_settings.dart';
import 'core/providers.dart';
import 'core/storage/app_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  final dirs = await AppDirs.resolve();
  await TempFiles(dirs.temp).wipe(); // never keep scratch files across launches

  final raw = await JsonStore(dirs.data).read('settings');
  final settings = raw is Map<String, Object?> ? AppSettings.fromJson(raw) : const AppSettings();

  runApp(ProviderScope(
    overrides: [appDirsProvider.overrideWithValue(dirs)],
    child: PdfReaderApp(showOnboarding: !settings.onboardingDone),
  ));
}
