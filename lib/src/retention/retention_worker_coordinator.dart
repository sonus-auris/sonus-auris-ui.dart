import 'dart:async';

/// Long-lived workers that may read or create app-private retention artifacts.
enum RetentionWorkerKind { recorder, uploader, analyzer, exporter }

/// Destructive transitions that invalidate every outstanding worker lease.
enum RetentionRevocationReason { consentRevocation, accountDeletion }

/// Raised when a worker attempts to enter or commit after destructive cleanup
/// has been requested.
class RetentionAccessRevoked implements Exception {
  const RetentionAccessRevoked({required this.reason, this.worker});

  final RetentionRevocationReason reason;
  final RetentionWorkerKind? worker;

  @override
  String toString() {
    final workerLabel = worker == null ? 'Retention work' : worker!.name;
    return '$workerLabel is blocked by ${reason.name}.';
  }
}

/// Capability handed to one coordinated worker invocation.
///
/// Workers must call [throwIfRevoked] immediately before each durable local
/// write and must not detach untracked asynchronous writes after their callback
/// completes. The coordinator drains the callback before destructive cleanup,
/// so a valid worker cannot recreate a path after deletion.
class RetentionWorkerLease {
  RetentionWorkerLease._({
    required this._owner,
    required this.worker,
    required this.generation,
  });

  final RetentionWorkerCoordinator _owner;
  final RetentionWorkerKind worker;
  final int generation;

  bool get isCurrent => _owner._isCurrent(generation);

  void throwIfRevoked() {
    if (isCurrent) {
      return;
    }
    throw RetentionAccessRevoked(
      reason: _owner.revokedFor ?? RetentionRevocationReason.consentRevocation,
      worker: worker,
    );
  }

  /// Guard a synchronous durable commit with the current retention generation.
  T commit<T>(T Function() write) {
    throwIfRevoked();
    return write();
  }

  /// Guard an asynchronous durable commit. If revocation begins while the write
  /// is running, the enclosing worker remains active; destructive cleanup waits
  /// for it and then removes any output before completing.
  Future<T> commitAsync<T>(Future<T> Function() write) async {
    throwIfRevoked();
    return write();
  }
}

/// Serializes account deletion and consent revocation against recorder,
/// uploader, analyzer, and exporter work.
///
/// The destructive barrier is established synchronously before the first
/// `await`: new work is rejected and all existing leases become stale. Cleanup
/// then waits for every tracked callback to finish before deleting app-private
/// state. Consent may later be re-authorized explicitly; account deletion seals
/// the coordinator permanently.
class RetentionWorkerCoordinator {
  int _generation = 0;
  int _activeWorkers = 0;
  bool _acceptingWork = true;
  bool _permanentlyClosed = false;
  bool _localStateCleared = false;
  RetentionRevocationReason? _revokedFor;
  Completer<void>? _idleCompleter;
  Future<void>? _barrierFuture;

  int get generation => _generation;
  int get activeWorkers => _activeWorkers;
  bool get acceptsWork => _acceptingWork;
  bool get permanentlyClosed => _permanentlyClosed;
  bool get localStateCleared => _localStateCleared;
  RetentionRevocationReason? get revokedFor => _revokedFor;

  Future<T> runWorker<T>(
    RetentionWorkerKind worker,
    Future<T> Function(RetentionWorkerLease lease) operation,
  ) async {
    if (!_acceptingWork) {
      throw RetentionAccessRevoked(
        reason: _revokedFor ?? RetentionRevocationReason.consentRevocation,
        worker: worker,
      );
    }

    // There is no await between admission and accounting, so a destructive
    // transition cannot observe an admitted worker without also draining it.
    final lease = RetentionWorkerLease._(
      _owner: this,
      worker: worker,
      generation: _generation,
    );
    _activeWorkers += 1;
    try {
      final result = await operation(lease);
      // A worker that completed after revocation must not report durable success;
      // the barrier will clear any output after this callback drains.
      lease.throwIfRevoked();
      return result;
    } finally {
      _activeWorkers -= 1;
      if (_activeWorkers == 0) {
        final idle = _idleCompleter;
        _idleCompleter = null;
        if (idle != null && !idle.isCompleted) {
          idle.complete();
        }
      }
    }
  }

  /// Invalidate workers, drain them, then run one canonical local-retention
  /// clear. The callback must be idempotent and semantically equivalent for
  /// consent revocation and account deletion; account-specific remote/token
  /// deletion belongs outside this local worker barrier.
  ///
  /// Concurrent destructive requests coalesce. Account deletion dominates a
  /// concurrent or later consent revocation and prevents re-authorization. A
  /// failed account clear remains sealed but may be retried until
  /// [localStateCleared] becomes true.
  Future<void> revokeAndClear({
    required RetentionRevocationReason reason,
    required Future<void> Function() clearLocalState,
  }) {
    final existing = _barrierFuture;
    if (existing != null) {
      if (reason == RetentionRevocationReason.accountDeletion ||
          _permanentlyClosed) {
        _revokedFor = RetentionRevocationReason.accountDeletion;
        _permanentlyClosed = true;
      }
      return existing;
    }
    if (_permanentlyClosed && _localStateCleared) {
      return Future<void>.value();
    }

    final effectiveReason = _permanentlyClosed
        ? RetentionRevocationReason.accountDeletion
        : reason;

    // Establish the barrier synchronously. This ordering is the core safety
    // property: no new worker can race in while cleanup waits for existing work.
    _acceptingWork = false;
    _generation += 1;
    _revokedFor = effectiveReason;
    _localStateCleared = false;
    if (effectiveReason == RetentionRevocationReason.accountDeletion) {
      _permanentlyClosed = true;
    }

    final barrier = _drainAndClear(clearLocalState);
    _barrierFuture = barrier;
    // Clear only the bookkeeping future. The caller still receives the original
    // barrier error, while this side-chain deliberately consumes it so cleanup
    // failures are not reported twice as unhandled asynchronous errors.
    unawaited(
      barrier.then<void>(
        (_) => _clearBarrierReference(barrier),
        onError: (Object _, StackTrace _) => _clearBarrierReference(barrier),
      ),
    );
    return barrier;
  }

  void _clearBarrierReference(Future<void> barrier) {
    if (identical(_barrierFuture, barrier)) {
      _barrierFuture = null;
    }
  }

  Future<void> _drainAndClear(Future<void> Function() clearLocalState) async {
    if (_activeWorkers > 0) {
      _idleCompleter ??= Completer<void>();
      await _idleCompleter!.future;
    }
    await clearLocalState();
    _localStateCleared = true;
  }

  /// Admit a new generation only after consent-revocation cleanup completed.
  /// Account deletion is irreversible for this coordinator instance.
  Future<void> resumeAfterConsent() async {
    final barrier = _barrierFuture;
    if (barrier != null) {
      await barrier;
    }
    if (_permanentlyClosed) {
      throw StateError('Account deletion cannot be resumed.');
    }
    if (_revokedFor != RetentionRevocationReason.consentRevocation ||
        !_localStateCleared) {
      throw StateError(
        'Retention work cannot resume before consent cleanup completes.',
      );
    }
    _generation += 1;
    _revokedFor = null;
    _localStateCleared = false;
    _acceptingWork = true;
  }

  bool _isCurrent(int generation) =>
      _acceptingWork && generation == _generation;
}
