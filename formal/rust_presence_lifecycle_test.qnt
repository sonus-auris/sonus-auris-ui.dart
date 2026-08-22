module rust_presence_lifecycle_test {
  import rust_presence_lifecycle.* from "./rust_presence_lifecycle"

  run authenticatedHeartbeatTest =
    init
      .then(configure)
      .then(transport_ready(1))
      .then(authenticated(1))
      .then(heartbeat_timer(1))
      .expect(and {
        s.phase == PHASE_CONNECTED,
        s.generation == 1,
        s.authentication_sent,
        s.heartbeat_started,
        s.heartbeat_sent,
        lifecycle_safety,
      })

  run replacementMakesOldReadyStutterTest =
    init
      .then(configure)
      .then(configure)
      .then(stale_event(1))
      .expect(and {
        s.phase == PHASE_CONNECTING,
        s.generation == 2,
        not(s.authentication_sent),
        not(s.heartbeat_started),
        lifecycle_safety,
      })

  run staleFailureCannotCloseReplacementTest =
    init
      .then(configure)
      .then(transport_ready(1))
      .then(configure)
      .then(stale_event(1))
      .then(transport_ready(2))
      .then(authenticated(2))
      .expect(and {
        s.phase == PHASE_CONNECTED,
        s.generation == 2,
        lifecycle_safety,
      })

  run failureInvalidatesCloseCallbacksBeforeRetryTest =
    init
      .then(configure)
      .then(transport_failed(1))
      .then(stale_event(1))
      .then(retry_timer(2))
      .then(transport_ready(3))
      .then(authenticated(3))
      .expect(and {
        s.phase == PHASE_CONNECTED,
        s.generation == 3,
        s.retry_attempt == 0,
        lifecycle_safety,
      })

  run closeIsTerminalUntilExplicitConfigureTest =
    init
      .then(configure)
      .then(transport_ready(1))
      .then(close)
      .then(stale_event(1))
      .expect(and {
        s.phase == PHASE_CLOSED,
        s.generation == 2,
        not(s.authentication_sent),
        not(s.heartbeat_started),
        lifecycle_safety,
      })

  run explicitConfigureReopensAfterCloseTest =
    init
      .then(configure)
      .then(close)
      .then(configure)
      .expect(and {
        s.phase == PHASE_CONNECTING,
        s.generation == 3,
        lifecycle_safety,
      })

  run presenceBeforeAuthenticationIsRejectedTest =
    init
      .then(configure)
      .then(presence_frame(1))
      .fail()
}
