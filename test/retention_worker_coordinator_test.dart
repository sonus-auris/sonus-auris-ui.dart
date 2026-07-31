import 'dart:async';

import 'package:audio_dashcam/src/retention/retention_worker_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'consent revocation invalidates active workers before cleanup drains them',
    () async {
      final coordinator = RetentionWorkerCoordinator();
      final entered = Completer<RetentionWorkerLease>();
      final release = Completer<void>();
      final events = <String>[];

      final worker = coordinator.runWorker(
        RetentionWorkerKind.analyzer,
        (lease) async {
          events.add('worker-entered');
          entered.complete(lease);
          await release.future;
          events.add('worker-released');
          lease.throwIfRevoked();
          events.add('worker-commit');
        },
      );
      final lease = await entered.future;
      expect(lease.isCurrent, isTrue);
      expect(coordinator.activeWorkers, 1);

      final barrier = coordinator.revokeAndClear(
        reason: RetentionRevocationReason.consentRevocation,
        clearLocalState: () async {
          events.add('clear');
        },
      );

      expect(coordinator.acceptsWork, isFalse);
      expect(lease.isCurrent, isFalse);
      expect(events, ['worker-entered']);

      release.complete();
      await expectLater(worker, throwsA(isA<RetentionAccessRevoked>()));
      await barrier;

      expect(events, ['worker-entered', 'worker-released', 'clear']);
      expect(coordinator.activeWorkers, 0);
      expect(
        coordinator.revokedFor,
        RetentionRevocationReason.consentRevocation,
      );
    },
  );

  test(
    'new uploader and exporter work is rejected once a barrier starts',
    () async {
      final coordinator = RetentionWorkerCoordinator();
      final clearBlock = Completer<void>();
      final barrier = coordinator.revokeAndClear(
        reason: RetentionRevocationReason.consentRevocation,
        clearLocalState: () => clearBlock.future,
      );

      await expectLater(
        coordinator.runWorker(
          RetentionWorkerKind.uploader,
          (_) async => 'uploaded',
        ),
        throwsA(
          isA<RetentionAccessRevoked>()
              .having(
                (error) => error.reason,
                'reason',
                RetentionRevocationReason.consentRevocation,
              )
              .having(
                (error) => error.worker,
                'worker',
                RetentionWorkerKind.uploader,
              ),
        ),
      );
      await expectLater(
        coordinator.runWorker(
          RetentionWorkerKind.exporter,
          (_) async => 'exported',
        ),
        throwsA(isA<RetentionAccessRevoked>()),
      );

      clearBlock.complete();
      await barrier;
    },
  );

  test('consent can resume only after destructive cleanup completes', () async {
    final coordinator = RetentionWorkerCoordinator();
    final clearBlock = Completer<void>();
    final barrier = coordinator.revokeAndClear(
      reason: RetentionRevocationReason.consentRevocation,
      clearLocalState: () => clearBlock.future,
    );
    final resume = coordinator.resumeAfterConsent();

    expect(coordinator.acceptsWork, isFalse);
    clearBlock.complete();
    await barrier;
    await resume;

    expect(coordinator.acceptsWork, isTrue);
    expect(coordinator.revokedFor, isNull);
    expect(
      await coordinator.runWorker(
        RetentionWorkerKind.recorder,
        (lease) async => lease.commit(() => 'new-generation'),
      ),
      'new-generation',
    );
  });

  test('account deletion permanently seals the coordinator', () async {
    final coordinator = RetentionWorkerCoordinator();
    var clearCount = 0;

    await coordinator.revokeAndClear(
      reason: RetentionRevocationReason.accountDeletion,
      clearLocalState: () async {
        clearCount += 1;
      },
    );

    expect(coordinator.permanentlyClosed, isTrue);
    expect(coordinator.acceptsWork, isFalse);
    expect(clearCount, 1);
    await expectLater(
      coordinator.resumeAfterConsent(),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      coordinator.runWorker(
        RetentionWorkerKind.recorder,
        (_) async => 'resurrected',
      ),
      throwsA(
        isA<RetentionAccessRevoked>().having(
          (error) => error.reason,
          'reason',
          RetentionRevocationReason.accountDeletion,
        ),
      ),
    );

    // Repeated deletion is idempotent and does not run a second local clear.
    await coordinator.revokeAndClear(
      reason: RetentionRevocationReason.accountDeletion,
      clearLocalState: () async {
        clearCount += 1;
      },
    );
    expect(clearCount, 1);
  });

  test('account deletion dominates an in-flight consent revocation', () async {
    final coordinator = RetentionWorkerCoordinator();
    final clearBlock = Completer<void>();
    var clearCount = 0;

    final consentBarrier = coordinator.revokeAndClear(
      reason: RetentionRevocationReason.consentRevocation,
      clearLocalState: () async {
        clearCount += 1;
        await clearBlock.future;
      },
    );
    final accountBarrier = coordinator.revokeAndClear(
      reason: RetentionRevocationReason.accountDeletion,
      clearLocalState: () async {
        clearCount += 1;
      },
    );

    expect(identical(consentBarrier, accountBarrier), isTrue);
    expect(coordinator.permanentlyClosed, isTrue);
    expect(
      coordinator.revokedFor,
      RetentionRevocationReason.accountDeletion,
    );

    clearBlock.complete();
    await Future.wait([consentBarrier, accountBarrier]);
    expect(clearCount, 1);
    await expectLater(
      coordinator.resumeAfterConsent(),
      throwsA(isA<StateError>()),
    );
  });

  test('lease commit helpers reject stale durable writes', () async {
    final coordinator = RetentionWorkerCoordinator();
    final entered = Completer<RetentionWorkerLease>();
    final release = Completer<void>();
    var durableWrites = 0;

    final worker = coordinator.runWorker(
      RetentionWorkerKind.uploader,
      (lease) async {
        entered.complete(lease);
        await release.future;
        lease.commit(() => durableWrites += 1);
      },
    );
    final lease = await entered.future;
    final barrier = coordinator.revokeAndClear(
      reason: RetentionRevocationReason.consentRevocation,
      clearLocalState: () async {},
    );

    expect(
      () => lease.commit(() => durableWrites += 1),
      throwsA(isA<RetentionAccessRevoked>()),
    );
    release.complete();
    await expectLater(worker, throwsA(isA<RetentionAccessRevoked>()));
    await barrier;
    expect(durableWrites, 0);
  });
}
