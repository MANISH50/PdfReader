import 'dart:async';

import 'package:flutter/services.dart';

import '../core/security/limits.dart';
import 'file_names.dart';
import 'platform_services.dart';

/// Why an incoming file could not be received.
enum IncomingFailureKind { tooLarge, tooMany, noSpace, unreadable, rejected, unsupported }

class IncomingFailure {
  const IncomingFailure(this.kind, {this.displayName});
  final IncomingFailureKind kind;
  final String? displayName;

  static IncomingFailureKind kindFromCode(Object? code) => switch (code) {
        'tooLarge' => IncomingFailureKind.tooLarge,
        'tooMany' => IncomingFailureKind.tooMany,
        'noSpace' => IncomingFailureKind.noSpace,
        'rejected' => IncomingFailureKind.rejected,
        'unsupported' => IncomingFailureKind.unsupported,
        _ => IncomingFailureKind.unreadable,
      };
}

/// Optional extra surface of an [IncomingFileService]: files that arrived but
/// could not be copied in, so the UI can tell the user.
abstract interface class IncomingFailureSource {
  Stream<IncomingFailure> get failures;
}

/// [IncomingFileService] backed by the native `pdfreader/incoming` channels
/// (Android `IncomingFilesHandler.kt`, iOS `IncomingFilesPlugin` in
/// AppDelegate.swift). Native code copies each file into [inboxPath] with a
/// size cap and a generated name; this class only ever sees private paths.
///
/// On platforms without the native side (desktop, tests) it reports nothing.
class ChannelIncomingFileService implements IncomingFileService, IncomingFailureSource {
  ChannelIncomingFileService({
    required this.inboxPath,
    this.maxBytes = SecurityLimits.maxFileBytes,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel('pdfreader/incoming'),
        _events = eventChannel ?? const EventChannel('pdfreader/incoming/events');

  final String inboxPath;
  final int maxBytes;
  final MethodChannel _method;
  final EventChannel _events;

  // Single-subscription controllers buffer events until the router listens.
  final _files = StreamController<IncomingFile>();
  final _failures = StreamController<IncomingFailure>.broadcast();
  StreamSubscription<Object?>? _eventSub;
  Future<IncomingFile?>? _initial;

  @override
  Future<IncomingFile?> initialFile() => _initial ??= _configure();

  @override
  Stream<IncomingFile> get files {
    unawaited(initialFile());
    return _files.stream;
  }

  @override
  Stream<IncomingFailure> get failures => _failures.stream;

  Future<IncomingFile?> _configure() async {
    _eventSub = _events.receiveBroadcastStream().listen(
      (batch) => _emit(_parseBatch(batch)),
      onError: (Object _) {},
    );
    List<IncomingFile> first;
    try {
      final raw = await _method.invokeMethod<List<Object?>>(
        'configure',
        {'inbox': inboxPath, 'maxBytes': maxBytes},
      );
      first = _parseBatch(raw);
    } on MissingPluginException {
      await _eventSub?.cancel();
      _eventSub = null;
      return null; // no native side on this platform
    } on PlatformException {
      return null;
    }
    if (first.isEmpty) return null;
    _emit(first.skip(1));
    return first.first;
  }

  void _emit(Iterable<IncomingFile> files) {
    for (final f in files) {
      _files.add(f);
    }
  }

  /// Parses one native batch; failures go to [failures].
  List<IncomingFile> _parseBatch(Object? batch) {
    final out = <IncomingFile>[];
    if (batch is! List) return out;
    for (final e in batch) {
      if (e is! Map) continue;
      final path = e['path'];
      final name = e['displayName'];
      final source = e['sourceUri'];
      final error = e['error'];
      if (error != null || path is! String || !_isInInbox(path)) {
        _failures.add(IncomingFailure(
          IncomingFailure.kindFromCode(error ?? 'rejected'),
          displayName: name is String ? sanitizeDisplayName(name) : null,
        ));
        continue;
      }
      out.add(IncomingFile(
        path: path,
        displayName: pdfFileName(name is String ? name : null),
        sourceUri: source is String ? source : null,
      ));
    }
    return out;
  }

  bool _isInInbox(String path) {
    final root = inboxPath.endsWith('/') ? inboxPath : '$inboxPath/';
    return path.startsWith(root) && !path.contains('/../') && !path.contains('\u0000');
  }

  void dispose() {
    unawaited(_eventSub?.cancel());
    unawaited(_files.close());
    unawaited(_failures.close());
  }
}
