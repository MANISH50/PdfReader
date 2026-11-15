import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/platform/default_app_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pdfreader/system');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('Android guidance covers Open with / Always and clearing defaults', () {
    final info = DefaultAppInfo.forPlatform(TargetPlatform.android);
    final text = info.steps.map((s) => '${s.title} ${s.detail}').join(' ');
    expect(text, contains('Always'));
    expect(text, contains('PdfReader'));
    expect(info.clearDefaultSteps.map((s) => s.detail).join(' '), contains('Open by default'));
    expect(info.canOpenSettings, isTrue);
  });

  test('iOS guidance uses Share and explains there is no default PDF app', () {
    final info = DefaultAppInfo.forPlatform(TargetPlatform.iOS);
    expect(info.steps.map((s) => s.detail).join(' '), contains('Share'));
    expect(info.note, contains('doesn\'t let you choose'));
    expect(info.clearDefaultSteps, isEmpty);
    expect(info.canOpenSettings, isFalse);
  });

  test('desktop has a simple fallback', () {
    expect(DefaultAppInfo.forPlatform(TargetPlatform.linux).steps, isNotEmpty);
  });

  test('openForThisApp calls the channel on Android only', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'sdkInt' ? 34 : true;
    });
    const settings = DefaultAppSettings();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await settings.openForThisApp(), isFalse);
    expect(calls, isEmpty);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await settings.openForThisApp(), isTrue);
    expect(await settings.androidSdkInt(), 34);
    expect(calls, ['openDefaultAppSettings', 'sdkInt']);
  });

  test('openForThisApp is false when the native side is missing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await const DefaultAppSettings().openForThisApp(), isFalse);
  });
}
