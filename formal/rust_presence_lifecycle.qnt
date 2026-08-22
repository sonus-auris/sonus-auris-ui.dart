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
  pure val PHASE_CLOSED = 5

  pure val MAX_GENERATION = 7
  pure val MAX_RETRY_ATTEMPT = 3
  pure val GENERATIONS: Set[int] = Set(0, 1, 2, 3, 4, 5, 6, 7)

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

  // Explicit configuration replaces any older connection, including a
  // terminal close. Production closes the old transport before opening this
  // generation.
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
  action transport_failed(event_generation: int): bool = all {
    event_generation == s.generation,
    Set(
      PHASE_CONNECTING,
      PHASE_AUTHENTICATING,
      PHASE_CONNECTED
    ).contains(s.phase),
    s.generation < MAX_GENERATION,
    s' = {
      phase: PHASE_WAITING_TO_RETRY,
      generation: s.generation + 1,
      retry_attempt: if (s.retry_attempt < MAX_RETRY_ATTEMPT)
        s.retry_attempt + 1
      else
        MAX_RETRY_ATTEMPT,
      authentication_sent: false,
      heartbeat_started: false,
      heartbeat_sent: false,
    },
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
    s.retry_attempt <= MAX_RETRY_ATTEMPT,
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
  val terminal_close_reached = s.phase == PHASE_CLOSED
}
