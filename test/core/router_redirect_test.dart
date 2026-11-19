import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/app_router.dart';
import 'package:pdfreader/core/models/document_ref.dart';

void main() {
  const doc = DocumentRef(id: 'x', path: '/p/a.pdf', displayName: 'a.pdf', sizeBytes: 1);

  test('content:// or unknown locations from "Open with" go to Home, never an error page', () {
    for (final path in [
      '/com.android.providers.downloads.documents/document/42',
      '/external/file/123',
      '/storage/emulated/0/Download/a.pdf',
      '/nope',
    ]) {
      expect(routeRedirect(path, null), Routes.home, reason: path);
    }
    expect(routeRedirect('/x', null, showOnboarding: true), Routes.onboarding);
  });

  test('document routes need a document', () {
    expect(routeRedirect(Routes.viewer, null), Routes.home);
    expect(routeRedirect(Routes.export, 'junk'), Routes.home);
    expect(routeRedirect(Routes.viewer, doc), isNull);
    expect(routeRedirect(Routes.reader, null), Routes.home);
    expect(routeRedirect(Routes.reader, 'junk', showOnboarding: true), Routes.onboarding);
    expect(routeRedirect(Routes.reader, doc), isNull);
    expect(routeRedirect(Routes.home, null), isNull);
    expect(routeRedirect(Routes.settings, null), isNull);
  });
}
