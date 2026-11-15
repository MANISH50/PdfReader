import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/platform/incoming_file_service_impl.dart';
import 'package:pdfreader/platform/platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('pdfreader/incoming');
  const events = EventChannel('pdfreader/incoming/events');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const inbox = '/app/support/inbox';

  late MockStreamHandlerEventSink? sink;
  late List<Object?> configureResult;
  Map<Object?, Object?>? configureArgs;

  setUp(() {
    sink = null;
    configureArgs = null;
    configureResult = [];
    messenger.setMockMethodCallHandler(method, (call) async {
      expect(call.method, 'configure');
      configureArgs = call.arguments as Map<Object?, Object?>;
      return configureResult;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (args, s) => sink = s),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('configure passes inbox and size cap; no launch file -> null', () async {
    final s = ChannelIncomingFileService(inboxPath: inbox, maxBytes: 1234);
    expect(await s.initialFile(), isNull);
    expect(configureArgs, {'inbox': inbox, 'maxBytes': 1234});
    s.dispose();
  });

  test('launch batch: first is initial, rest arrive on the stream', () async {
    configureResult = [
      {'path': '$inbox/in_1.pdf', 'displayName': 'a.pdf', 'sourceUri': 'content://x/1', 'size': 10},
      {'path': '$inbox/in_2.pdf', 'displayName': '../b', 'sourceUri': 'content://x/2', 'size': 10},
    ];
    final s = ChannelIncomingFileService(inboxPath: inbox);
    final first = await s.initialFile();
    expect(first!.path, '$inbox/in_1.pdf');
    expect(first.displayName, 'a.pdf');
    expect(first.sourceUri, 'content://x/1');
    final next = await s.files.first;
    expect(next.path, '$inbox/in_2.pdf');
    expect(next.displayName, 'b.pdf'); // re-sanitised in Dart
    s.dispose();
  });

  test('files received while running arrive on the stream; failures reported', () async {
    final s = ChannelIncomingFileService(inboxPath: inbox);
    final got = <IncomingFile>[];
    final failures = <IncomingFailure>[];
    s.failures.listen(failures.add);
    s.files.listen(got.add);
    await s.initialFile();
    expect(sink, isNotNull);
    sink!.success([
      {'path': '$inbox/in_3.pdf', 'displayName': 'c.pdf'},
      {'error': 'tooLarge', 'displayName': 'huge.pdf'},
      // Paths outside the inbox are never trusted, whatever native says.
      {'path': '/etc/passwd', 'displayName': 'x.pdf'},
      {'path': '$inbox/../data/settings.json', 'displayName': 'y.pdf'},
    ]);
    await pumpEventQueue();
    expect(got.map((f) => f.path), ['$inbox/in_3.pdf']);
    expect(failures.map((f) => f.kind),
        [IncomingFailureKind.tooLarge, IncomingFailureKind.rejected, IncomingFailureKind.rejected]);
    expect(failures.first.displayName, 'huge.pdf');
    s.dispose();
  });

  test('no native side (desktop) -> nothing, no throw', () async {
    messenger.setMockMethodCallHandler(method, null);
    final s = ChannelIncomingFileService(inboxPath: inbox);
    expect(await s.initialFile(), isNull);
    s.dispose();
  });

  test('error codes map to failure kinds', () {
    expect(IncomingFailure.kindFromCode('tooMany'), IncomingFailureKind.tooMany);
    expect(IncomingFailure.kindFromCode('noSpace'), IncomingFailureKind.noSpace);
    expect(IncomingFailure.kindFromCode('unsupported'), IncomingFailureKind.unsupported);
    expect(IncomingFailure.kindFromCode('weird'), IncomingFailureKind.unreadable);
  });
}
