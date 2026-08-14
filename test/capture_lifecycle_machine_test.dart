import 'package:flutter_test/flutter_test.dart';
import 'package:audio_dashcam/src/app/capture_lifecycle_machine.dart';

void main() {
  group('CaptureLifecycleMachine', () {
    test('start, pause, resume, restart, and stop form one valid trace', () {
      var state = const CaptureLifecycleSnapshot.initial();

      var transition = CaptureLifecycleMachine.transition(
        state,
        const CaptureEvent.startRequested(),
      );
      expect(transition.effect?.kind, CaptureEffectKind.startCapture);
      state = transition.after;
      state = CaptureLifecycleMachine.transition(
        state,
        CaptureEvent.operationSucceeded(state.activeOperationId!),
      ).after;
      expect(state.phase, CapturePhase.recording);

      transition = CaptureLifecycleMachine.transition(
        state,
        const CaptureEvent.pauseRequested(),
      );
      expect(transition.effect?.kind, CaptureEffectKind.stopCapture);
      state = CaptureLifecycleMachine.transition(
        transition.after,
        CaptureEvent.operationSucceeded(transition.after.activeOperationId!),
      ).after;
      expect(state.phase, CapturePhase.paused);

      transition = CaptureLifecycleMachine.transition(
        state,
        const CaptureEvent.resumeRequested(),
      );
      state = CaptureLifecycleMachine.transition(
        transition.after,
        CaptureEvent.operationSucceeded(transition.after.activeOperationId!),
      ).after;
      expect(state.phase, CapturePhase.recording);

      transition = CaptureLifecycleMachine.transition(
        state,
        const CaptureEvent.restartRequested(),
      );
      expect(transition.effect?.kind, CaptureEffectKind.restartCapture);
      state = CaptureLifecycleMachine.transition(
        transition.after,
        CaptureEvent.operationSucceeded(transition.after.activeOperationId!),
      ).after;
      expect(state.phase, CapturePhase.recording);

      transition = CaptureLifecycleMachine.transition(
        state,
        const CaptureEvent.stopRequested(),
      );
      state = CaptureLifecycleMachine.transition(
        transition.after,
        CaptureEvent.operationSucceeded(transition.after.activeOperationId!),
      ).after;
      expect(state.phase, CapturePhase.stopped);
      expect(state.validate(), isNull);
    });

    test('stale async completion cannot commit over a newer stop', () {
      const initial = CaptureLifecycleSnapshot.initial();
      final start = CaptureLifecycleMachine.transition(
        initial,
        const CaptureEvent.startRequested(),
      );
      final stop = CaptureLifecycleMachine.transition(
        start.after,
        const CaptureEvent.stopRequested(),
      );
      final staleStart = CaptureLifecycleMachine.transition(
        stop.after,
        CaptureEvent.operationSucceeded(start.effect!.operationId),
      );

      expect(staleStart.disposition, CaptureTransitionDisposition.stale);
      expect(staleStart.after, stop.after);
      expect(staleStart.after.phase, CapturePhase.stopping);

      final stopped = CaptureLifecycleMachine.transition(
        staleStart.after,
        CaptureEvent.operationSucceeded(stop.effect!.operationId),
      );
      expect(stopped.after.phase, CapturePhase.stopped);
    });

    test('retryable interruption has an explicit recovery path', () {
      var state = _recordingState();
      state = CaptureLifecycleMachine.transition(
        state,
        const CaptureEvent.captureInterrupted(
          reason: 'audio service reset',
          retryable: true,
        ),
      ).after;
      expect(state.phase, CapturePhase.failed);
      expect(state.capabilities.canRecover, isTrue);

      final recovery = CaptureLifecycleMachine.transition(
        state,
        const CaptureEvent.recoveryRequested(),
      );
      expect(recovery.effect?.operation, CaptureOperation.recover);
      final recovered = CaptureLifecycleMachine.transition(
        recovery.after,
        CaptureEvent.operationSucceeded(recovery.effect!.operationId),
      );
      expect(recovered.after.phase, CapturePhase.recording);
    });

    test('UI capabilities are mutually controlled', () {
      const stopped = CaptureLifecycleSnapshot.initial();
      expect(stopped.capabilities.canStart, isTrue);
      expect(stopped.capabilities.canStop, isFalse);
      expect(stopped.capabilities.canRestart, isFalse);

      final recording = _recordingState();
      expect(recording.capabilities.canStart, isFalse);
      expect(recording.capabilities.canStop, isTrue);
      expect(recording.capabilities.canRestart, isTrue);
      expect(recording.capabilities.canPause, isTrue);
    });

    test(
      'fatal failure requires a stop reconciliation before another start',
      () {
        final start = CaptureLifecycleMachine.transition(
          const CaptureLifecycleSnapshot.initial(),
          const CaptureEvent.startRequested(),
        );
        final failed = CaptureLifecycleMachine.transition(
          start.after,
          CaptureEvent.operationFailed(
            start.effect!.operationId,
            reason: 'microphone state is unknown',
            retryable: false,
          ),
        );
        expect(failed.after.phase, CapturePhase.failed);
        expect(failed.after.capabilities.canStart, isFalse);
        expect(failed.after.capabilities.canStop, isTrue);

        final rejectedStart = CaptureLifecycleMachine.transition(
          failed.after,
          const CaptureEvent.startRequested(),
        );
        expect(
          rejectedStart.disposition,
          CaptureTransitionDisposition.rejected,
        );

        final stop = CaptureLifecycleMachine.transition(
          failed.after,
          const CaptureEvent.stopRequested(),
        );
        final stopped = CaptureLifecycleMachine.transition(
          stop.after,
          CaptureEvent.operationSucceeded(stop.effect!.operationId),
        );
        expect(stopped.after.phase, CapturePhase.stopped);
        expect(stopped.after.capabilities.canStart, isTrue);
      },
    );

    test(
      'bounded reachable graph is total, deterministic, and invariant-safe',
      () {
        final frontier = <CaptureLifecycleSnapshot>[
          const CaptureLifecycleSnapshot.initial(),
        ];
        final seen = <CaptureLifecycleSnapshot>{};
        final reached = <CapturePhase>{};

        while (frontier.isNotEmpty && seen.length < 500) {
          final state = frontier.removeLast();
          if (!seen.add(state) || state.generation >= 4) continue;
          reached.add(state.phase);
          expect(state.validate(), isNull, reason: 'invalid ${state.phase}');

          for (final event in _eventsFor(state)) {
            final first = CaptureLifecycleMachine.transition(state, event);
            final second = CaptureLifecycleMachine.transition(state, event);
            expect(first, second, reason: '${state.phase} + ${event.kind}');
            expect(first.after.validate(), isNull);
            if (!seen.contains(first.after)) frontier.add(first.after);
          }
        }

        expect(
          seen.length,
          lessThan(500),
          reason: 'bounded exploration must exhaust before its safety cap',
        );

        expect(
          reached,
          containsAll(<CapturePhase>{
            CapturePhase.stopped,
            CapturePhase.starting,
            CapturePhase.recording,
            CapturePhase.stopping,
            CapturePhase.restarting,
            CapturePhase.paused,
            CapturePhase.failed,
          }),
        );
      },
    );
  });
}

CaptureLifecycleSnapshot _recordingState() {
  final start = CaptureLifecycleMachine.transition(
    const CaptureLifecycleSnapshot.initial(),
    const CaptureEvent.startRequested(),
  );
  return CaptureLifecycleMachine.transition(
    start.after,
    CaptureEvent.operationSucceeded(start.effect!.operationId),
  ).after;
}

Iterable<CaptureEvent> _eventsFor(CaptureLifecycleSnapshot state) sync* {
  yield const CaptureEvent.startRequested();
  yield const CaptureEvent.stopRequested();
  yield const CaptureEvent.restartRequested();
  yield const CaptureEvent.pauseRequested();
  yield const CaptureEvent.resumeRequested();
  yield const CaptureEvent.recoveryRequested();
  yield const CaptureEvent.captureInterrupted(
    reason: 'retryable interruption',
    retryable: true,
  );
  yield const CaptureEvent.captureInterrupted(
    reason: 'fatal interruption',
    retryable: false,
  );
  yield const CaptureEvent.serviceRecoveredRecording();
  yield const CaptureEvent.serviceRecoveredStopped();
  yield const CaptureEvent.operationSucceeded(999);
  yield const CaptureEvent.operationFailed(
    999,
    reason: 'stale',
    retryable: true,
  );
  final operationId = state.activeOperationId;
  if (operationId != null) {
    yield CaptureEvent.operationSucceeded(operationId);
    yield CaptureEvent.operationFailed(
      operationId,
      reason: 'retryable',
      retryable: true,
    );
    yield CaptureEvent.operationFailed(
      operationId,
      reason: 'fatal',
      retryable: false,
    );
  }
}
