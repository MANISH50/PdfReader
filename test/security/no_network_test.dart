// Privacy invariants: the app is fully offline and ships no tracking code.
// Scans the source tree and lockfile; run from the package root (flutter test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source patterns that would let app code talk to the network or hand a URL
/// to the OS without our confirmation dialog.
final forbiddenSource = <String, RegExp>{
  'dart:io HttpClient': RegExp(r'\bHttpClient\b'),
  'dart:io HttpServer': RegExp(r'\bHttpServer\b'),
  'WebSocket': RegExp(r'\bWebSocket\b'),
  'Socket.connect / raw sockets': RegExp(r'\b(Secure)?(Raw)?(Datagram)?Socket\s*\.\s*(connect|bind|startConnect)\b'),
  'ServerSocket': RegExp(r'\b(Raw)?(Secure)?ServerSocket\b'),
  'DNS lookup': RegExp(r'\bInternetAddress\s*\.\s*lookup\b'),
  'package:http': RegExp(r'''import\s+['"]package:http/'''),
  'package:dio': RegExp(r'''import\s+['"]package:dio/'''),
  'package:web_socket_channel': RegExp(r'''import\s+['"]package:web_socket_channel/'''),
  'package:grpc': RegExp(r'''import\s+['"]package:grpc/'''),
  'WebView': RegExp(r'''import\s+['"]package:(webview_flutter|flutter_inappwebview)'''),
  'pdfrx network open': RegExp(r'\b(openUri|PdfDocumentRefUri|createHttpClient)\b|PdfViewer\s*\.\s*uri\b'),
  'network images': RegExp(r'\bNetworkImage\b|Image\s*\.\s*network\b'),
  'dart:html / web http': RegExp(r'''import\s+['"]dart:html['"]|\bHttpRequest\b'''),
};

/// url_launcher may only be used by the confirmed-link helper, which must run
/// every URL through LinkPolicy. The helper is any file named
/// `link_opener.dart`, `link_launcher.dart`, `url_opener.dart` or `url_launcher.dart`.
final launcherImport = RegExp(r'''import\s+['"]package:url_launcher''');
final launcherHelperName = RegExp(r'(link|url)_(opener|launcher)\.dart$');

/// Analytics, ads, crash reporting, attribution, remote config, push.
final trackerNames = RegExp(
  r'firebase|crashlytics|sentry|google_mobile_ads|admob|amplitude|mixpanel|segment_analytics|analytics|'
  r'appsflyer|adjust_sdk|branch_sdk|facebook|meta_sdk|datadog|bugsnag|newrelic|new_relic|posthog|instabug|'
  r'onesignal|applovin|unity_ads|ironsource|appcenter|countly|matomo|smartlook|uxcam|clarity|launchdarkly|'
  r'heap_|braze|clevertap|airship|tiktok|snapchat|play_install_referrer|advertising_id',
  caseSensitive: false,
);

String stripComments(String src) {
  // Block comments, then whole-line // comments (keeps '//' inside URLs/strings intact).
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock.split('\n').map((l) => l.trimLeft().startsWith('//') ? '' : l).join('\n');
}

List<String> scanSource(String path, String src) {
  final code = stripComments(src);
  final hits = <String>[];
  forbiddenSource.forEach((name, re) {
    if (re.hasMatch(code)) hits.add('$path: $name');
  });
  if (launcherImport.hasMatch(code)) {
    if (!launcherHelperName.hasMatch(path.replaceAll(r'\', '/'))) {
      hits.add('$path: url_launcher outside the confirmed-link helper');
    } else if (!code.contains('LinkPolicy')) {
      hits.add('$path: link helper does not consult LinkPolicy');
    }
  }
  final importRe = RegExp(r'''(import|export)\s+['"]package:([a-zA-Z0-9_]+)/''');
  for (final m in importRe.allMatches(code)) {
    if (trackerNames.hasMatch(m.group(2)!)) hits.add('$path: tracker package ${m.group(2)}');
  }
  return hits;
}

/// Package names listed in a pubspec.lock `packages:` section.
List<String> lockPackages(String lock) =>
    RegExp(r'^  ([a-z0-9_]+):\s*$', multiLine: true).allMatches(lock).map((m) => m.group(1)!).toList();

void main() {
  test('scanner self-check catches forbidden code', () {
    expect(scanSource('lib/a.dart', 'final c = HttpClient();'), isNotEmpty);
    expect(scanSource('lib/a.dart', "import 'package:http/http.dart' as http;"), isNotEmpty);
    expect(scanSource('lib/a.dart', 'await Socket.connect(host, 80);'), isNotEmpty);
    expect(scanSource('lib/a.dart', "import 'package:firebase_analytics/firebase_analytics.dart';"), isNotEmpty);
    expect(scanSource('lib/a.dart', 'PdfDocument.openUri(Uri.parse(u));'), isNotEmpty);
    expect(scanSource('lib/a.dart', 'PdfViewer.uri(u)'), isNotEmpty);
    expect(scanSource('lib/viewer.dart', "import 'package:url_launcher/url_launcher.dart';"), isNotEmpty);
    expect(scanSource('lib/core/security/link_opener.dart', "import 'package:url_launcher/url_launcher.dart';"),
        isNotEmpty, reason: 'helper without LinkPolicy');
    expect(
        scanSource('lib/core/security/link_opener.dart',
            "import 'package:url_launcher/url_launcher.dart';\nfinal d = LinkPolicy.decide(uri: u);"),
        isEmpty);
    expect(scanSource('lib/a.dart', '// no HttpClient here\n/* nor WebSocket */\nfinal s = "https://x";'), isEmpty);
    expect(lockPackages('packages:\n  firebase_core:\n    dependency: direct\n'), ['firebase_core']);
  });

  test('lib/ contains no networking, WebView or tracker code', () {
    final hits = <String>[];
    final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    for (final f in files) {
      hits.addAll(scanSource(f.path, f.readAsStringSync()));
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('pubspec.lock contains no analytics/ads/crash-reporting packages', () {
    final pkgs = lockPackages(File('pubspec.lock').readAsStringSync());
    expect(pkgs, contains('pdfrx'), reason: 'lockfile parse sanity check');
    final bad = pkgs.where(trackerNames.hasMatch).toList();
    expect(bad, isEmpty, reason: 'tracking packages in lockfile: $bad');
  });

  test('pubspec.yaml declares no networking client package directly', () {
    final yaml = File('pubspec.yaml').readAsStringSync();
    for (final pkg in ['http', 'dio', 'web_socket_channel', 'grpc', 'webview_flutter', 'flutter_inappwebview',
        'cached_network_image', 'firebase_core', 'sentry_flutter']) {
      expect(RegExp('^\\s+$pkg:', multiLine: true).hasMatch(yaml), isFalse, reason: pkg);
    }
  });

  test('main AndroidManifest requests no network or storage permissions', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final perm in [
      'INTERNET', 'ACCESS_NETWORK_STATE', 'ACCESS_WIFI_STATE', 'READ_EXTERNAL_STORAGE', 'WRITE_EXTERNAL_STORAGE',
      'MANAGE_EXTERNAL_STORAGE', 'READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO', 'READ_MEDIA_AUDIO', 'QUERY_ALL_PACKAGES',
      'REQUEST_INSTALL_PACKAGES', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'CAMERA', 'RECORD_AUDIO',
      'READ_CONTACTS', 'READ_PHONE_STATE', 'AD_ID',
    ]) {
      expect(RegExp('uses-permission[^>]*android\\.permission\\.$perm\\b|com\\.google\\.android\\.gms\\.permission\\.$perm')
              .hasMatch(stripXmlComments(manifest)),
          isFalse,
          reason: perm);
    }
  });
}

String stripXmlComments(String xml) => xml.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
