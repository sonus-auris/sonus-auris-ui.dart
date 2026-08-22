/// Pure lifecycle authority for the secondary Rust presence WebSocket.
///
/// Every asynchronous transport callback carries the generation of the
/// connection that installed it. Events from an older generation stutter, so
/// they cannot authenticate, mark connected, close, heartbeat, or schedule a
/// retry over a replacement connection.
enum RustPresencePhase {
  idle,
  connecting,
  authenticating,
  connected,
  waitingToRetry,
  closed,
}

enum RustPresenceInput {
  configure,
  transportReady,
  authenticated,
  presenceFrame,
  heartbeatTimer,
  transportFailed,
  retryTimer,
  close,
}

enum RustPresenceEffect {
  closeTransport,
  openTransport,
  sendAuthentication,
  startHeartbeat,
  sendHeartbeat,
  scheduleReconnect,
}

final class RustPresenceTransition {
  const RustPresenceTransition({required this.state, this.effects = const []});

  final RustPresenceLifecycle state;
  final List<RustPresenceEffect> effects;

  bool get isStutter => effects.isEmpty;
}

final class RustPresenceLifecycle {
  const RustPresenceLifecycle({
    this.phase = RustPresencePhase.idle,
    this.generation = 0,
    this.retryAttempt = 0,
  });

  static const int maxRetryAttempt = 7;
  static const Duration maxReconnectDelay = Duration(minutes: 1);

  final RustPresencePhase phase;
  final int generation;
  final int retryAttempt;

  bool get acceptsPresence => phase == RustPresencePhase.connected;

  bool get isValid {
    if (generation < 0 || retryAttempt < 0 || retryAttempt > maxRetryAttempt) {
      return false;
    }
    if ((phase == RustPresencePhase.idle ||
            phase == RustPresencePhase.closed) &&
        retryAttempt != 0) {
      return false;
    }
    return true;
  }

  Duration get reconnectDelay {
    if (phase != RustPresencePhase.waitingToRetry || retryAttempt == 0) {
      return Duration.zero;
    }
    final exponent = (retryAttempt - 1).clamp(0, 6).toInt();
    final seconds = 1 << exponent;
    return seconds >= maxReconnectDelay.inSeconds
        ? maxReconnectDelay
        : Duration(seconds: seconds);
  }

  RustPresenceTransition advance(
    RustPresenceInput input, {
    int? eventGeneration,
  }) {
    if (input == RustPresenceInput.configure) {
      return RustPresenceTransition(
        state: RustPresenceLifecycle(
          phase: RustPresencePhase.connecting,
          generation: generation + 1,
        ),
        effects: const [
          RustPresenceEffect.closeTransport,
          RustPresenceEffect.openTransport,
        ],
      );
    }

    if (input == RustPresenceInput.close) {
      if (phase == RustPresencePhase.closed) {
        return RustPresenceTransition(state: this);
      }
      return RustPresenceTransition(
        state: RustPresenceLifecycle(
          phase: RustPresencePhase.closed,
          generation: generation + 1,
        ),
        effects: const [RustPresenceEffect.closeTransport],
      );
    }

    // All transport/timer events are scoped to their originating generation.
    // Missing generations fail closed just like stale generations.
    if (eventGeneration != generation) {
      return RustPresenceTransition(state: this);
    }

    switch (input) {
      case RustPresenceInput.transportReady:
        if (phase != RustPresencePhase.connecting) {
          return RustPresenceTransition(state: this);
        }
        return RustPresenceTransition(
          state: RustPresenceLifecycle(
            phase: RustPresencePhase.authenticating,
            generation: generation,
            retryAttempt: retryAttempt,
          ),
          effects: const [RustPresenceEffect.sendAuthentication],
        );
      case RustPresenceInput.authenticated:
        if (phase != RustPresencePhase.authenticating) {
          return RustPresenceTransition(state: this);
        }
        return RustPresenceTransition(
          state: RustPresenceLifecycle(
            phase: RustPresencePhase.connected,
            generation: generation,
          ),
          effects: const [RustPresenceEffect.startHeartbeat],
        );
      case RustPresenceInput.presenceFrame:
        return RustPresenceTransition(state: this);
      case RustPresenceInput.heartbeatTimer:
        if (phase != RustPresencePhase.connected) {
          return RustPresenceTransition(state: this);
        }
        return RustPresenceTransition(
          state: this,
          effects: const [RustPresenceEffect.sendHeartbeat],
        );
      case RustPresenceInput.transportFailed:
        if (phase != RustPresencePhase.connecting &&
            phase != RustPresencePhase.authenticating &&
            phase != RustPresencePhase.connected) {
          return RustPresenceTransition(state: this);
        }
        final nextAttempt = (retryAttempt + 1).clamp(1, maxRetryAttempt);
        return RustPresenceTransition(
          state: RustPresenceLifecycle(
            phase: RustPresencePhase.waitingToRetry,
            generation: generation + 1,
            retryAttempt: nextAttempt,
          ),
          effects: const [
            RustPresenceEffect.closeTransport,
            RustPresenceEffect.scheduleReconnect,
          ],
        );
      case RustPresenceInput.retryTimer:
        if (phase != RustPresencePhase.waitingToRetry) {
          return RustPresenceTransition(state: this);
        }
        return RustPresenceTransition(
          state: RustPresenceLifecycle(
            phase: RustPresencePhase.connecting,
            generation: generation + 1,
            retryAttempt: retryAttempt,
          ),
          effects: const [RustPresenceEffect.openTransport],
        );
      case RustPresenceInput.configure:
      case RustPresenceInput.close:
        throw StateError('Global lifecycle inputs must be handled first.');
    }
  }
}
