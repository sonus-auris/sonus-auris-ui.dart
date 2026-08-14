// Total, deterministic bounded model of the Sonus Auris capture lifecycle.
//
// Stable phases: stopped, recording, paused, failed.
// Transitional phases: starting, stopping, restarting.
// Unsupported state/event pairs stutter. Async results commit only when their
// operation token matches the active generation.
module capture_lifecycle {
  type State = {
    phase: int,
    generation: int,
    operation: int,
    active_token: int,
    intends_capture: bool,
    has_failure: bool,
  }

  pure val STOPPED = 0
  pure val STARTING = 1
  pure val RECORDING = 2
  pure val STOPPING = 3
  pure val RESTARTING = 4
  pure val PAUSED = 5
  pure val FAILED = 6

  pure val OP_NONE = 0
  pure val OP_START = 1
  pure val OP_STOP = 2
  pure val OP_RESTART = 3
  pure val OP_PAUSE = 4
  pure val OP_RESUME = 5
  pure val OP_RECOVER = 6

  pure val START_REQUESTED = 1
  pure val STOP_REQUESTED = 2
  pure val RESTART_REQUESTED = 3
  pure val PAUSE_REQUESTED = 4
  pure val RESUME_REQUESTED = 5
  pure val RECOVERY_REQUESTED = 6
  pure val OPERATION_SUCCEEDED = 7
  pure val OPERATION_FAILED = 8
  pure val CAPTURE_INTERRUPTED = 9
  pure val SERVICE_RECOVERED_RECORDING = 10
  pure val SERVICE_RECOVERED_STOPPED = 11

  pure val MAX_GENERATION = 4

  pure val PHASES = Set(
    STOPPED,
    STARTING,
    RECORDING,
    STOPPING,
    RESTARTING,
    PAUSED,
    FAILED
  )
  pure val OPERATIONS = Set(
    OP_NONE,
    OP_START,
    OP_STOP,
    OP_RESTART,
    OP_PAUSE,
    OP_RESUME,
    OP_RECOVER
  )
  pure val EVENTS = Set(
    START_REQUESTED,
    STOP_REQUESTED,
    RESTART_REQUESTED,
    PAUSE_REQUESTED,
    RESUME_REQUESTED,
    RECOVERY_REQUESTED,
    OPERATION_SUCCEEDED,
    OPERATION_FAILED,
    CAPTURE_INTERRUPTED,
    SERVICE_RECOVERED_RECORDING,
    SERVICE_RECOVERED_STOPPED
  )
  pure val TOKENS = Set(0, 1, 2, 3, 4, 99)
  pure val BOOLS: Set[bool] = Set(true, false)

  var s: State

  pure def stable(
    current: State,
    next_phase: int,
    next_intent: bool,
    failed: bool
  ): State = {
    ...current,
    phase: next_phase,
    operation: OP_NONE,
    active_token: 0,
    intends_capture: next_intent,
    has_failure: failed,
  }

  pure def begin(
    current: State,
    next_phase: int,
    next_operation: int,
    next_intent: bool
  ): State =
    if (current.generation >= MAX_GENERATION)
      current
    else {
      ...current,
      phase: next_phase,
      generation: current.generation + 1,
      operation: next_operation,
      active_token: current.generation + 1,
      intends_capture: next_intent,
      has_failure: false,
    }

  pure def retry_intent(operation: int, retryable: bool): bool =
    retryable and Set(OP_START, OP_RESTART, OP_RESUME, OP_RECOVER)
      .contains(operation)

  pure def complete_success(current: State, token: int): State =
    if (current.operation == OP_NONE or current.active_token != token)
      current
    else if (current.operation == OP_STOP)
      stable(current, STOPPED, false, false)
    else if (current.operation == OP_PAUSE)
      stable(current, PAUSED, true, false)
    else
      stable(current, RECORDING, true, false)

  pure def complete_failure(
    current: State,
    token: int,
    retryable: bool
  ): State =
    if (current.operation == OP_NONE or current.active_token != token)
      current
    else
      stable(
        current,
        FAILED,
        retry_intent(current.operation, retryable),
        true
      )

  // This pure operator is the entire state relation. It is defined for every
  // bounded State × Event × Token × retryable input.
  pure def transition(
    current: State,
    event: int,
    token: int,
    retryable: bool
  ): State =
    if (event == START_REQUESTED)
      if (current.phase == STOPPED)
        begin(current, STARTING, OP_START, true)
      else
        current
    else if (event == STOP_REQUESTED)
      if (current.phase != STOPPED and current.phase != STOPPING)
        begin(current, STOPPING, OP_STOP, false)
      else
        current
    else if (event == RESTART_REQUESTED)
      if (
        current.phase == RECORDING
        or (current.phase == FAILED and current.intends_capture)
      )
        begin(current, RESTARTING, OP_RESTART, true)
      else
        current
    else if (event == PAUSE_REQUESTED)
      if (current.phase == RECORDING)
        begin(current, STOPPING, OP_PAUSE, true)
      else
        current
    else if (event == RESUME_REQUESTED)
      if (current.phase == PAUSED)
        begin(current, STARTING, OP_RESUME, true)
      else
        current
    else if (event == RECOVERY_REQUESTED)
      if (current.phase == FAILED and current.intends_capture)
        begin(current, STARTING, OP_RECOVER, true)
      else
        current
    else if (event == OPERATION_SUCCEEDED)
      complete_success(current, token)
    else if (event == OPERATION_FAILED)
      complete_failure(current, token, retryable)
    else if (event == CAPTURE_INTERRUPTED)
      if (current.phase == RECORDING)
        stable(current, FAILED, retryable, true)
      else
        current
    else if (event == SERVICE_RECOVERED_RECORDING)
      if (current.phase == FAILED and current.intends_capture)
        stable(current, RECORDING, true, false)
      else
        current
    else if (event == SERVICE_RECOVERED_STOPPED)
      if (current.phase == RECORDING)
        stable(current, FAILED, true, true)
      else
        current
    else
      current

  action init: bool = {
    s' = {
      phase: STOPPED,
      generation: 0,
      operation: OP_NONE,
      active_token: 0,
      intends_capture: false,
      has_failure: false,
    }
  }

  action apply(
    event: int,
    token: int,
    retryable: bool
  ): bool = all {
    EVENTS.contains(event),
    TOKENS.contains(token),
    BOOLS.contains(retryable),
    s' = transition(s, event, token, retryable),
  }

  action step: bool = {
    nondet event = EVENTS.oneOf()
    nondet token = TOKENS.oneOf()
    nondet retryable = BOOLS.oneOf()
    apply(event, token, retryable)
  }

  val domain_bounds = and {
    PHASES.contains(s.phase),
    OPERATIONS.contains(s.operation),
    s.generation >= 0,
    s.generation <= MAX_GENERATION,
    s.active_token >= 0,
    s.active_token <= MAX_GENERATION,
  }

  val transitional_iff_operation_active =
    Set(STARTING, STOPPING, RESTARTING).contains(s.phase)
      == (s.operation != OP_NONE and s.active_token != 0)

  val operation_token_is_current =
    s.operation == OP_NONE
      or (s.active_token > 0 and s.active_token == s.generation)

  val operation_matches_phase = and {
    (s.phase == STARTING).implies(
      Set(OP_START, OP_RESUME, OP_RECOVER).contains(s.operation)
    ),
    (s.phase == STOPPING).implies(
      Set(OP_STOP, OP_PAUSE).contains(s.operation)
    ),
    (s.phase == RESTARTING).implies(s.operation == OP_RESTART),
  }

  val stable_state_intent_is_coherent = and {
    (s.phase == STOPPED).implies(not(s.intends_capture)),
    (s.phase == RECORDING).implies(s.intends_capture),
    (s.phase == PAUSED).implies(s.intends_capture),
  }

  val failure_is_controlled =
    s.has_failure == (s.phase == FAILED)

  val capture_lifecycle_safety = and {
    domain_bounds,
    transitional_iff_operation_active,
    operation_token_is_current,
    operation_matches_phase,
    stable_state_intent_is_coherent,
    failure_is_controlled,
  }

  val stopped_reached = s.phase == STOPPED
  val starting_reached = s.phase == STARTING
  val recording_reached = s.phase == RECORDING
  val stopping_reached = s.phase == STOPPING
  val restarting_reached = s.phase == RESTARTING
  val paused_reached = s.phase == PAUSED
  val failed_reached = s.phase == FAILED
}
