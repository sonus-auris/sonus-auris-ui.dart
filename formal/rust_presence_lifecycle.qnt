// Bounded model of the Flutter client's secondary Rust presence WebSocket.
// Every transport and timer callback is tagged with the generation that
// installed it. A callback from any other generation must stutter.
module rust_presence_lifecycle {
  type State = {
    phase: int,
    generation: int,
    retry_attempt: int,
    authentication_sent: bool,
    heartbeat_started: bool,
    heartbeat_sent: bool,
  }

  pure val PHASE_IDLE = 0
  pure val PHASE_CONNECTING = 1
  pure val PHASE_AUTHENTICATING = 2
  pure val PHASE_CONNECTED = 3
  pure val PHASE_WAITING_TO_RETRY = 4
  pure val PHASE_RETRY_EXHAUSTED = 5
  pure val PHASE_CLOSED = 6

  pure val MAX_GENERATION = 20
  pure val MAX_RETRY_ATTEMPTS = 7
  pure val GENERATIONS: Set[int] = Set(
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20
  )

  var s: State

  action init: bool = {
    s' = {
      phase: PHASE_IDLE,
      generation: 0,
      retry_attempt: 0,
      authentication_sent: false,
      heartbeat_started: false,
      heartbeat_sent: false,
    }
  }

  // Explicit configuration replaces any older connection and resets the
  // finite retry budget, including after close or retry exhaustion.
  action configure: bool = all {
    s.generation < MAX_GENERATION,
    s' = {
      phase: PHASE_CONNECTING,
      generation: s.generation + 1,
      retry_attempt: 0,
      authentication_sent: false,
      heartbeat_started: false,
      heartbeat_sent: false,
    },
  }

  action transport_ready(event_generation: int): bool = all {
    event_generation == s.generation,
    s.phase == PHASE_CONNECTING,
    s' = {
      ...s,
      phase: PHASE_AUTHENTICATING,
      authentication_sent: true,
    },
  }

  action authenticated(event_generation: int): bool = all {
    event_generation == s.generation,
    s.phase == PHASE_AUTHENTICATING,
    s.authentication_sent,
    s' = {
      ...s,
      phase: PHASE_CONNECTED,
      retry_attempt: 0,
      heartbeat_started: true,
    },
  }

  action presence_frame(event_generation: int): bool = all {
    event_generation == s.generation,
    s.phase == PHASE_CONNECTED,
    s' = s,
  }

  action heartbeat_timer(event_generation: int): bool = all {
    event_generation == s.generation,
    s.phase == PHASE_CONNECTED,
    s.heartbeat_started,
    s' = { ...s, heartbeat_sent: true },
  }

  // Failure invalidates the failing connection before close callbacks can run.
  action transport_failed_retry(event_generation: int): bool = all {
    event_generation == s.generation,
    Set(
      PHASE_CONNECTING,
      PHASE_AUTHENTICATING,
      PHASE_CONNECTED
    ).contains(s.phase),
    s.retry_attempt < MAX_RETRY_ATTEMPTS,
    s.generation < MAX_GENERATION,
    s' = {
      phase: PHASE_WAITING_TO_RETRY,
      generation: s.generation + 1,
      retry_attempt: s.retry_attempt + 1,
      authentication_sent: false,
      heartbeat_started: false,
      heartbeat_sent: false,
    },
  }

  action transport_failed_exhausted(event_generation: int): bool = all {
    event_generation == s.generation,
    Set(
      PHASE_CONNECTING,
      PHASE_AUTHENTICATING,
      PHASE_CONNECTED
    ).contains(s.phase),
    s.retry_attempt == MAX_RETRY_ATTEMPTS,
    s.generation < MAX_GENERATION,
    s' = {
      phase: PHASE_RETRY_EXHAUSTED,
      generation: s.generation + 1,
      retry_attempt: s.retry_attempt,
      authentication_sent: false,
      heartbeat_started: false,
      heartbeat_sent: false,
    },
  }

  action transport_failed(event_generation: int): bool = any {
    transport_failed_retry(event_generation),
    transport_failed_exhausted(event_generation),
  }

  action retry_timer(event_generation: int): bool = all {
    event_generation == s.generation,
    s.phase == PHASE_WAITING_TO_RETRY,
    s.generation < MAX_GENERATION,
    s' = {
      ...s,
      phase: PHASE_CONNECTING,
      generation: s.generation + 1,
    },
  }

  // Close invalidates the active generation. Nothing reopens until configure.
  action close: bool = all {
    s.phase != PHASE_CLOSED,
    s.generation < MAX_GENERATION,
    s' = {
      phase: PHASE_CLOSED,
      generation: s.generation + 1,
      retry_attempt: 0,
      authentication_sent: false,
      heartbeat_started: false,
      heartbeat_sent: false,
    },
  }

  action stale_event(event_generation: int): bool = all {
    GENERATIONS.contains(event_generation),
    event_generation != s.generation,
    s' = s,
  }

  action idle: bool = s' = s

  action step: bool = {
    nondet event_generation = GENERATIONS.oneOf()
    any {
      configure,
      transport_ready(event_generation),
      authenticated(event_generation),
      presence_frame(event_generation),
      heartbeat_timer(event_generation),
      transport_failed(event_generation),
      retry_timer(event_generation),
      close,
      stale_event(event_generation),
      idle,
    }
  }

  val lifecycle_safety = and {
    s.phase >= PHASE_IDLE,
    s.phase <= PHASE_CLOSED,
    s.generation >= 0,
    s.generation <= MAX_GENERATION,
    s.retry_attempt >= 0,
    s.retry_attempt <= MAX_RETRY_ATTEMPTS,
    (s.phase == PHASE_IDLE).implies(and {
      s.generation == 0,
      s.retry_attempt == 0,
      not(s.authentication_sent),
      not(s.heartbeat_started),
      not(s.heartbeat_sent),
    }),
    (s.phase == PHASE_CONNECTING).implies(and {
      not(s.authentication_sent),
      not(s.heartbeat_started),
      not(s.heartbeat_sent),
    }),
    (s.phase == PHASE_AUTHENTICATING).implies(and {
      s.authentication_sent,
      not(s.heartbeat_started),
      not(s.heartbeat_sent),
    }),
    (s.phase == PHASE_CONNECTED).implies(and {
      s.authentication_sent,
      s.heartbeat_started,
    }),
    (s.phase == PHASE_WAITING_TO_RETRY).implies(and {
      s.retry_attempt > 0,
      not(s.authentication_sent),
      not(s.heartbeat_started),
      not(s.heartbeat_sent),
    }),
    (s.phase == PHASE_RETRY_EXHAUSTED).implies(and {
      s.retry_attempt == MAX_RETRY_ATTEMPTS,
      not(s.authentication_sent),
      not(s.heartbeat_started),
      not(s.heartbeat_sent),
    }),
    (s.phase == PHASE_CLOSED).implies(and {
      s.retry_attempt == 0,
      not(s.authentication_sent),
      not(s.heartbeat_started),
      not(s.heartbeat_sent),
    }),
    s.heartbeat_sent.implies(and {
      s.phase == PHASE_CONNECTED,
      s.authentication_sent,
      s.heartbeat_started,
    }),
  }

  val authenticated_connection_reached = s.phase == PHASE_CONNECTED
  val retry_wait_reached = s.phase == PHASE_WAITING_TO_RETRY
  val retry_exhausted_reached = s.phase == PHASE_RETRY_EXHAUSTED
  val terminal_close_reached = s.phase == PHASE_CLOSED
}
