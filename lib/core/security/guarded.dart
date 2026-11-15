import 'dart:async';
import 'dart:collection';

import '../pdf/document_service.dart';

/// A guarded operation did not finish in time. The underlying work may still
/// be running (Dart futures cannot be killed); pass `onTimeout` to cancel it
/// (e.g. a pdfrx cancellation token).
class OperationTimeoutException implements Exception {
  const OperationTimeoutException(this.operation, this.timeout);
  final String operation;
  final Duration timeout;
  @override
  String toString() => 'OperationTimeoutException($operation after ${timeout.inMilliseconds} ms)';
}

/// A [TaskLimiter] refused work (queue full or limiter disposed).
class TaskRejectedException implements Exception {
  const TaskRejectedException(this.reason);
  final String reason;
  @override
  String toString() => 'TaskRejectedException($reason)';
}

/// Runs [task] and throws [OperationTimeoutException] if it takes longer than
/// [timeout]. Only the deadline is mapped: a `TimeoutException` thrown by
/// [task] itself propagates unchanged. A late result or error from [task]
/// after the deadline is ignored (never surfaces as an unhandled error).
Future<T> withTimeout<T>(
  Future<T> Function() task,
  Duration timeout, {
  required String operation,
  void Function()? onTimeout,
}) {
  final Future<T> future;
  try {
    future = task();
  } catch (e, st) {
    return Future<T>.error(e, st);
  }
  return future.timeout(timeout, onTimeout: () {
    onTimeout?.call();
    throw OperationTimeoutException(operation, timeout);
  });
}

/// [withTimeout] for document opening: maps the deadline to
/// `DocumentOpenException(OpenFailure.timeout)`.
Future<T> withOpenTimeout<T>(Future<T> Function() task, Duration timeout, {void Function()? onTimeout}) async {
  try {
    return await withTimeout(task, timeout, operation: 'open', onTimeout: onTimeout);
  } on OperationTimeoutException {
    throw const DocumentOpenException(OpenFailure.timeout);
  }
}

/// Bounds how many heavy jobs (page renders, text extraction, thumbnails,
/// export) run at once, so a hostile PDF cannot fan out unbounded work.
///
/// A slot is held until the task's future really completes, even if the
/// caller gave up (timeout): that is the point of the limit.
class TaskLimiter {
  TaskLimiter({required this.maxConcurrent, this.maxQueued = 256, this.newestFirst = false})
      : assert(maxConcurrent > 0),
        assert(maxQueued >= 0);

  final int maxConcurrent;

  /// Waiting tasks beyond this are rejected with [TaskRejectedException]
  /// (or, with [newestFirst], the oldest waiting task is rejected instead).
  final int maxQueued;

  /// LIFO scheduling: useful for rendering, where the most recently requested
  /// page is the one on screen.
  final bool newestFirst;

  final _queue = ListQueue<_Job<Object?>>();
  int _active = 0;
  bool _disposed = false;

  int get active => _active;
  int get queued => _queue.length;

  /// Runs [task] when a slot is free. If [isCancelled] returns true when the
  /// task reaches the front of the queue, it is skipped and
  /// [TaskRejectedException] is thrown. If [timeout] is given, the caller's
  /// future fails with [OperationTimeoutException] after that long *running*.
  Future<T> run<T>(
    Future<T> Function() task, {
    bool Function()? isCancelled,
    Duration? timeout,
    String operation = 'task',
  }) {
    if (_disposed) return Future.error(const TaskRejectedException('disposed'));
    final job = _Job<T>(task, isCancelled, timeout, operation);
    if (_queue.length >= maxQueued && _active >= maxConcurrent) {
      if (!newestFirst || _queue.isEmpty) {
        return Future.error(const TaskRejectedException('queue full'));
      }
      _queue.removeFirst().completer.completeError(const TaskRejectedException('superseded'));
    }
    _queue.add(job);
    _pump();
    return job.completer.future;
  }

  /// Rejects all waiting tasks; running ones finish normally.
  void dispose() {
    _disposed = true;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.completeError(const TaskRejectedException('disposed'));
    }
  }

  void _pump() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final job = newestFirst ? _queue.removeLast() : _queue.removeFirst();
      if (job.isCancelled?.call() ?? false) {
        job.completer.completeError(const TaskRejectedException('cancelled'));
        continue;
      }
      _active++;
      unawaited(_start(job));
    }
  }

  Future<void> _start<T>(_Job<T> job) async {
    final Future<T> work;
    try {
      work = Future.sync(job.task);
    } catch (e, st) {
      _active--;
      job.completer.completeError(e, st);
      _pump();
      return;
    }
    Timer? timer;
    if (job.timeout != null) {
      timer = Timer(job.timeout!, () {
        if (!job.completer.isCompleted) {
          job.completer.completeError(OperationTimeoutException(job.operation, job.timeout!));
        }
      });
    }
    try {
      final v = await work;
      if (!job.completer.isCompleted) job.completer.complete(v);
    } catch (e, st) {
      if (!job.completer.isCompleted) job.completer.completeError(e, st);
    } finally {
      timer?.cancel();
      _active--;
      _pump();
    }
  }
}

class _Job<T> {
  _Job(this.task, this.isCancelled, this.timeout, this.operation);
  final Future<T> Function() task;
  final bool Function()? isCancelled;
  final Duration? timeout;
  final String operation;
  final completer = Completer<T>();
}
