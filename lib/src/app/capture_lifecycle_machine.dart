/// Total, deterministic capture lifecycle used by the mobile and Flutter
/// desktop applications.
///
/// Platform and recorder calls remain fallible effects. This module owns every
/// application-visible capture state change and turns unsupported requests,
/// stale completions, and failures into explicit controlled outcomes.
library;

enum CapturePhase {
  stopped,
  starting,
  recording,
  stopping,
  restarting,
  paused,
  failed,
}

enum CaptureOperation { start, stop, restart, pause, resume, recover }

enum CaptureEventKind {
  startRequested,
  stopRequested,
  restartRequested,
  pauseRequested,
  resumeRequested,
  recoveryRequested,
  operationSucceeded,
  operationFailed,
  captureInterrupted,
  serviceRecoveredRecording,
  serviceRecoveredStopped,
}

enum CaptureEffectKind { startCapture, stopCapture, restartCapture }

enum CaptureTransitionDisposition { applied, rejected, stale }

class CaptureEvent {
  const CaptureEvent._(
    this.kind, {
    this.operationId,
    this.reason,
    this.retryable = false,
  });

  const CaptureEvent.startRequested() : this._(CaptureEventKind.startRequested);
  const CaptureEvent.stopRequested() : this._(CaptureEventKind.stopRequested);
  const CaptureEvent.restartRequested()
    : this._(CaptureEventKind.restartRequested);
  const CaptureEvent.pauseRequested() : this._(CaptureEventKind.pauseRequested);
  const CaptureEvent.resumeRequested()
    : this._(CaptureEventKind.resumeRequested);
  const CaptureEvent.recoveryRequested()
    : this._(CaptureEventKind.recoveryRequested);
  const CaptureEvent.operationSucceeded(int operationId)
    : this._(CaptureEventKind.operationSucceeded, operationId: operationId);
  const CaptureEvent.operationFailed(
    int operationId, {
    required String reason,
    required bool retryable,
  }) : this._(
         CaptureEventKind.operationFailed,
         operationId: operationId,
         reason: reason,
         retryable: retryable,
       );
  const CaptureEvent.captureInterrupted({
    required String reason,
    required bool retryable,
  }) : this._(
         CaptureEventKind.captureInterrupted,
         reason: reason,
         retryable: retryable,
       );
  const CaptureEvent.serviceRecoveredRecording()
    : this._(CaptureEventKind.serviceRecoveredRecording);
  const CaptureEvent.serviceRecoveredStopped({
    String reason = 'Capture service stopped unexpectedly.',
  }) : this._(
         CaptureEventKind.serviceRecoveredStopped,
         reason: reason,
         retryable: true,
       );

  final CaptureEventKind kind;
  final int? operationId;
  final String? reason;
  final bool retryable;

  @override
  bool operator ==(Object other) =>
      other is CaptureEvent &&
      kind == other.kind &&
      operationId == other.operationId &&
      reason == other.reason &&
      retryable == other.retryable;

  @override
  int get hashCode => Object.hash(kind, operationId, reason, retryable);
}

class CaptureEffect {
  const CaptureEffect({
    required this.kind,
    required this.operation,
    required this.operationId,
  });

  final CaptureEffectKind kind;
  final CaptureOperation operation;
  final int operationId;

  @override
  bool operator ==(Object other) =>
      other is CaptureEffect &&
      kind == other.kind &&
      operation == other.operation &&
      operationId == other.operationId;

  @override
  int get hashCode => Object.hash(kind, operation, operationId);
}

class CaptureCapabilities {
  const CaptureCapabilities({
    required this.canStart,
    required this.canStop,
    required this.canRestart,
    required this.canPause,
    required this.canResume,
    required this.canRecover,
  });

  final bool canStart;
  final bool canStop;
  final bool canRestart;
  final bool canPause;
  final bool canResume;
  final bool canRecover;
}

class CaptureLifecycleSnapshot {
  const CaptureLifecycleSnapshot._({
    required this.phase,
    required this.generation,
    required this.intendsCapture,
    this.activeOperation,
    this.activeOperationId,
    this.failure,
  });

  const CaptureLifecycleSnapshot.initial()
    : this._(phase: CapturePhase.stopped, generation: 0, intendsCapture: false);

  final CapturePhase phase;
  final int generation;
  final bool intendsCapture;
  final CaptureOperation? activeOperation;
  final int? activeOperationId;
  final String? failure;

  bool get isBusy => switch (phase) {
    CapturePhase.starting ||
    CapturePhase.stopping ||
    CapturePhase.restarting => true,
    _ => false,
  };

  bool get isRecording => phase == CapturePhase.recording;

  CaptureCapabilities get capabilities => CaptureCapabilities(
    canStart: phase == CapturePhase.stopped,
    canStop: phase != CapturePhase.stopped && phase != CapturePhase.stopping,
    canRestart:
        phase == CapturePhase.recording ||
        (phase == CapturePhase.failed && intendsCapture),
    canPause: phase == CapturePhase.recording,
    canResume: phase == CapturePhase.paused,
    canRecover: phase == CapturePhase.failed && intendsCapture,
  );

  /// Runtime invariant used at every production transition boundary.
  String? validate() {
    if (generation < 0) return 'generation must be non-negative';
    final transitional = isBusy;
    if (transitional !=
        (activeOperation != null && activeOperationId != null)) {
      return 'transitional phases require exactly one active operation';
    }
    if ((activeOperation == null) != (activeOperationId == null)) {
      return 'active operation and id must appear together';
    }
    if (activeOperationId != null &&
        (activeOperationId! <= 0 || activeOperationId != generation)) {
      return 'active operation id must equal the current generation';
    }
    final operationMatchesPhase = switch (phase) {
      CapturePhase.starting =>
        activeOperation == CaptureOperation.start ||
            activeOperation == CaptureOperation.resume ||
            activeOperation == CaptureOperation.recover,
      CapturePhase.stopping =>
        activeOperation == CaptureOperation.stop ||
            activeOperation == CaptureOperation.pause,
      CapturePhase.restarting => activeOperation == CaptureOperation.restart,
      _ => activeOperation == null,
    };
    if (!operationMatchesPhase) {
      return 'active operation is incompatible with the current phase';
    }
    if (phase == CapturePhase.recording && !intendsCapture) {
      return 'recording requires capture intent';
    }
    if (phase == CapturePhase.paused && !intendsCapture) {
      return 'paused requires capture intent';
    }
    if (phase == CapturePhase.stopped && intendsCapture) {
      return 'stopped cannot retain capture intent';
    }
    if ((phase == CapturePhase.failed) != (failure != null)) {
      return 'failure details must exist exactly in the failed phase';
    }
    return null;
  }

  CaptureLifecycleSnapshot _begin(
    CaptureOperation operation,
    CapturePhase nextPhase, {
    required bool intendsCapture,
  }) {
    final nextGeneration = generation + 1;
    return CaptureLifecycleSnapshot._(
      phase: nextPhase,
      generation: nextGeneration,
      intendsCapture: intendsCapture,
      activeOperation: operation,
      activeOperationId: nextGeneration,
    );
  }

  CaptureLifecycleSnapshot _stable(
    CapturePhase nextPhase, {
    required bool intendsCapture,
    String? failure,
  }) => CaptureLifecycleSnapshot._(
    phase: nextPhase,
    generation: generation,
    intendsCapture: intendsCapture,
    failure: failure,
  );

  @override
  bool operator ==(Object other) =>
      other is CaptureLifecycleSnapshot &&
      phase == other.phase &&
      generation == other.generation &&
      intendsCapture == other.intendsCapture &&
      activeOperation == other.activeOperation &&
      activeOperationId == other.activeOperationId &&
      failure == other.failure;

  @override
  int get hashCode => Object.hash(
    phase,
    generation,
    intendsCapture,
    activeOperation,
    activeOperationId,
    failure,
  );
}

class CaptureTransition {
  const CaptureTransition({
    required this.before,
    required this.after,
    required this.disposition,
    required this.reason,
    this.effect,
  });

  final CaptureLifecycleSnapshot before;
  final CaptureLifecycleSnapshot after;
  final CaptureTransitionDisposition disposition;
  final String reason;
  final CaptureEffect? effect;

  bool get wasApplied => disposition == CaptureTransitionDisposition.applied;

  @override
  bool operator ==(Object other) =>
      other is CaptureTransition &&
      before == other.before &&
      after == other.after &&
      disposition == other.disposition &&
      reason == other.reason &&
      effect == other.effect;

  @override
  int get hashCode => Object.hash(before, after, disposition, reason, effect);
}

class CaptureLifecycleMachine {
  const CaptureLifecycleMachine._();

  /// Pure transition relation. It is total for every valid snapshot and event:
  /// unsupported pairs return an explicit rejection, and old async completions
  /// return an explicit stale result without changing state.
  static CaptureTransition transition(
    CaptureLifecycleSnapshot current,
    CaptureEvent event,
  ) {
    final invalid = current.validate();
    if (invalid != null) {
      return CaptureTransition(
        before: current,
        after: const CaptureLifecycleSnapshot.initial(),
        disposition: CaptureTransitionDisposition.rejected,
        reason: 'Invalid lifecycle snapshot failed closed: $invalid',
      );
    }

    return switch (event.kind) {
      CaptureEventKind.startRequested => _begin(
        current,
        allowed: current.phase == CapturePhase.stopped,
        operation: CaptureOperation.start,
        phase: CapturePhase.starting,
        effect: CaptureEffectKind.startCapture,
        rejection: 'Start is unavailable from ${current.phase.name}.',
      ),
      CaptureEventKind.stopRequested => _begin(
        current,
        allowed:
            current.phase != CapturePhase.stopped &&
            current.phase != CapturePhase.stopping,
        operation: CaptureOperation.stop,
        phase: CapturePhase.stopping,
        effect: CaptureEffectKind.stopCapture,
        intendsCapture: false,
        rejection: 'Stop is unavailable from ${current.phase.name}.',
      ),
      CaptureEventKind.restartRequested => _begin(
        current,
        allowed:
            current.phase == CapturePhase.recording ||
            (current.phase == CapturePhase.failed && current.intendsCapture),
        operation: CaptureOperation.restart,
        phase: CapturePhase.restarting,
        effect: CaptureEffectKind.restartCapture,
        rejection: 'Restart is unavailable from ${current.phase.name}.',
      ),
      CaptureEventKind.pauseRequested => _begin(
        current,
        allowed: current.phase == CapturePhase.recording,
        operation: CaptureOperation.pause,
        phase: CapturePhase.stopping,
        effect: CaptureEffectKind.stopCapture,
        rejection: 'Pause requires live recording.',
      ),
      CaptureEventKind.resumeRequested => _begin(
        current,
        allowed: current.phase == CapturePhase.paused,
        operation: CaptureOperation.resume,
        phase: CapturePhase.starting,
        effect: CaptureEffectKind.startCapture,
        rejection: 'Resume requires a paused recorder.',
      ),
      CaptureEventKind.recoveryRequested => _begin(
        current,
        allowed: current.phase == CapturePhase.failed && current.intendsCapture,
        operation: CaptureOperation.recover,
        phase: CapturePhase.starting,
        effect: CaptureEffectKind.startCapture,
        rejection: 'Recovery requires a retryable failed recorder.',
      ),
      CaptureEventKind.operationSucceeded => _complete(
        current,
        event,
        succeeded: true,
      ),
      CaptureEventKind.operationFailed => _complete(
        current,
        event,
        succeeded: false,
      ),
      CaptureEventKind.captureInterrupted => _interrupt(current, event),
      CaptureEventKind.serviceRecoveredRecording => _recoverRecording(current),
      CaptureEventKind.serviceRecoveredStopped => _recoverStopped(
        current,
        event,
      ),
    };
  }

  static CaptureTransition _begin(
    CaptureLifecycleSnapshot current, {
    required bool allowed,
    required CaptureOperation operation,
    required CapturePhase phase,
    required CaptureEffectKind effect,
    required String rejection,
    bool intendsCapture = true,
  }) {
    if (!allowed) return _rejected(current, rejection);
    final next = current._begin(
      operation,
      phase,
      intendsCapture: intendsCapture,
    );
    return _applied(
      current,
      next,
      '${operation.name} operation accepted.',
      effect: CaptureEffect(
        kind: effect,
        operation: operation,
        operationId: next.activeOperationId!,
      ),
    );
  }

  static CaptureTransition _complete(
    CaptureLifecycleSnapshot current,
    CaptureEvent event, {
    required bool succeeded,
  }) {
    if (event.operationId == null ||
        event.operationId != current.activeOperationId ||
        current.activeOperation == null) {
      return CaptureTransition(
        before: current,
        after: current,
        disposition: CaptureTransitionDisposition.stale,
        reason:
            'Completion ${event.operationId ?? 'without id'} does not match active operation ${current.activeOperationId ?? 'none'}.',
      );
    }

    if (!succeeded) {
      final retryIntent =
          event.retryable &&
          switch (current.activeOperation!) {
            CaptureOperation.start ||
            CaptureOperation.restart ||
            CaptureOperation.resume ||
            CaptureOperation.recover => true,
            CaptureOperation.stop || CaptureOperation.pause => false,
          };
      final next = current._stable(
        CapturePhase.failed,
        intendsCapture: retryIntent,
        failure: _controlledReason(event.reason),
      );
      return _applied(current, next, 'Operation failed in a controlled state.');
    }

    final target = switch (current.activeOperation!) {
      CaptureOperation.stop => CapturePhase.stopped,
      CaptureOperation.pause => CapturePhase.paused,
      CaptureOperation.start ||
      CaptureOperation.restart ||
      CaptureOperation.resume ||
      CaptureOperation.recover => CapturePhase.recording,
    };
    final next = current._stable(
      target,
      intendsCapture: target != CapturePhase.stopped,
    );
    return _applied(current, next, 'Operation completed.');
  }

  static CaptureTransition _interrupt(
    CaptureLifecycleSnapshot current,
    CaptureEvent event,
  ) {
    if (current.phase != CapturePhase.recording) {
      return _rejected(
        current,
        'Capture interruption is unavailable from ${current.phase.name}.',
      );
    }
    final next = current._stable(
      CapturePhase.failed,
      intendsCapture: event.retryable,
      failure: _controlledReason(event.reason),
    );
    return _applied(current, next, 'Capture interruption controlled.');
  }

  static CaptureTransition _recoverRecording(CaptureLifecycleSnapshot current) {
    if (current.phase != CapturePhase.failed || !current.intendsCapture) {
      return _rejected(
        current,
        'Service recovery requires a retryable failed recorder.',
      );
    }
    final next = current._stable(CapturePhase.recording, intendsCapture: true);
    return _applied(current, next, 'Recovered a live capture service.');
  }

  static CaptureTransition _recoverStopped(
    CaptureLifecycleSnapshot current,
    CaptureEvent event,
  ) {
    if (current.phase != CapturePhase.recording) {
      return _rejected(
        current,
        'Stopped service recovery requires a recording state.',
      );
    }
    final next = current._stable(
      CapturePhase.failed,
      intendsCapture: true,
      failure: _controlledReason(event.reason),
    );
    return _applied(current, next, 'Unexpected service stop controlled.');
  }

  static String _controlledReason(String? reason) {
    final trimmed = reason?.trim() ?? '';
    return trimmed.isEmpty ? 'Capture operation failed.' : trimmed;
  }

  static CaptureTransition _applied(
    CaptureLifecycleSnapshot before,
    CaptureLifecycleSnapshot after,
    String reason, {
    CaptureEffect? effect,
  }) {
    final invalid = after.validate();
    if (invalid != null) {
      return CaptureTransition(
        before: before,
        after: const CaptureLifecycleSnapshot.initial(),
        disposition: CaptureTransitionDisposition.rejected,
        reason: 'Transition result failed closed: $invalid',
      );
    }
    return CaptureTransition(
      before: before,
      after: after,
      disposition: CaptureTransitionDisposition.applied,
      reason: reason,
      effect: effect,
    );
  }

  static CaptureTransition _rejected(
    CaptureLifecycleSnapshot current,
    String reason,
  ) => CaptureTransition(
    before: current,
    after: current,
    disposition: CaptureTransitionDisposition.rejected,
    reason: reason,
  );
}
