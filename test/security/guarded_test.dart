import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/core/pdf/document_service.dart';
import 'package:pdfreader/core/security/guarded.dart';

void main() {
  group('withTimeout', () {
    test('returns the value when in time', () async {
      expect(await withTimeout(() async => 42, const Duration(seconds: 1), operation: 'x'), 42);
    });

    test('maps the deadline to OperationTimeoutException and calls onTimeout', () async {
      var cancelled = false;
      final never = Completer<int>();
      final sw = Stopwatch()..start();
      await expectLater(
          withTimeout(() => never.future, const Duration(milliseconds: 50), operation: 'render', onTimeout: () {
            cancelled = true;
          }),
          throwsA(isA<OperationTimeoutException>().having((e) => e.operation, 'operation', 'render')));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(45));
      expect(cancelled, isTrue);
      // Late failure of the abandoned work must not surface as unhandled.
      never.completeError(StateError('late'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('task-thrown TimeoutException is not remapped; sync throws become errors', () async {
      await expectLater(
          withTimeout<int>(() => Future.error(TimeoutException('inner')), const Duration(seconds: 1), operation: 'x'),
          throwsA(isA<TimeoutException>()));
      await expectLater(withTimeout<int>(() => throw ArgumentError('sync'), const Duration(seconds: 1), operation: 'x'),
          throwsArgumentError);
    });

    test('withOpenTimeout maps to DocumentOpenException(timeout)', () async {
      await expectLater(
          withOpenTimeout(() => Completer<int>().future, const Duration(milliseconds: 20)),
          throwsA(isA<DocumentOpenException>().having((e) => e.failure, 'failure', OpenFailure.timeout)));
    });
  });

  group('TaskLimiter', () {
    test('never exceeds maxConcurrent', () async {
      final limiter = TaskLimiter(maxConcurrent: 2);
      var running = 0;
      var peak = 0;
      final results = await Future.wait(List.generate(20, (i) => limiter.run(() async {
            running++;
            peak = peak < running ? running : peak;
            await Future<void>.delayed(const Duration(milliseconds: 2));
            running--;
            return i;
          })));
      expect(results, List.generate(20, (i) => i));
      expect(peak, 2);
      expect(limiter.active, 0);
      expect(limiter.queued, 0);
    });

    test('errors propagate and free the slot', () async {
      final limiter = TaskLimiter(maxConcurrent: 1);
      await expectLater(limiter.run<int>(() async => throw StateError('boom')), throwsStateError);
      await expectLater(limiter.run<int>(() => throw StateError('sync boom')), throwsStateError);
      expect(await limiter.run(() async => 1), 1);
    });

    test('queue cap rejects excess work', () async {
      final limiter = TaskLimiter(maxConcurrent: 1, maxQueued: 2);
      final gate = Completer<void>();
      final first = limiter.run(() => gate.future);
      final q1 = limiter.run(() async => 1);
      final q2 = limiter.run(() async => 2);
      await expectLater(limiter.run(() async => 3), throwsA(isA<TaskRejectedException>()));
      gate.complete();
      await first;
      expect(await q1, 1);
      expect(await q2, 2);
    });

    test('newestFirst runs latest request first and supersedes oldest when full', () async {
      final limiter = TaskLimiter(maxConcurrent: 1, maxQueued: 2, newestFirst: true);
      final order = <int>[];
      final gate = Completer<void>();
      final first = limiter.run(() => gate.future);
      final a = limiter.run(() async => order.add(1));
      final b = limiter.run(() async => order.add(2));
      final c = limiter.run(() async => order.add(3)); // supersedes a
      await expectLater(a, throwsA(isA<TaskRejectedException>()));
      gate.complete();
      await Future.wait([first, b, c]);
      expect(order, [3, 2]);
    });

    test('cancelled tasks are skipped', () async {
      final limiter = TaskLimiter(maxConcurrent: 1);
      final gate = Completer<void>();
      final first = limiter.run(() => gate.future);
      var ran = false;
      var cancel = false;
      final second = limiter.run(() async => ran = true, isCancelled: () => cancel);
      cancel = true;
      gate.complete();
      await first;
      await expectLater(second, throwsA(isA<TaskRejectedException>()));
      expect(ran, isFalse);
    });

    test('timeout fails the caller but keeps the slot until work ends', () async {
      final limiter = TaskLimiter(maxConcurrent: 1);
      final hung = Completer<int>();
      final first = limiter.run(() => hung.future, timeout: const Duration(milliseconds: 30), operation: 'text');
      var secondDone = false;
      final second = limiter.run(() async => secondDone = true);
      await expectLater(first, throwsA(isA<OperationTimeoutException>()));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(secondDone, isFalse, reason: 'slot still held by hung work');
      hung.complete(1);
      await second;
      expect(secondDone, isTrue);
    });

    test('dispose rejects queued work', () async {
      final limiter = TaskLimiter(maxConcurrent: 1);
      final gate = Completer<void>();
      final first = limiter.run(() => gate.future);
      final queued = limiter.run(() async => 1);
      limiter.dispose();
      await expectLater(queued, throwsA(isA<TaskRejectedException>()));
      await expectLater(limiter.run(() async => 1), throwsA(isA<TaskRejectedException>()));
      gate.complete();
      await first;
    });
  });
}
