module capture_lifecycle_test {
  import capture_lifecycle.* from "./capture_lifecycle"

  run startStopTest =
    init
      .then(apply(START_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 1, false))
      .then(apply(STOP_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 2, false))
      .expect(and {
        s.phase == STOPPED,
        not(s.intends_capture),
        capture_lifecycle_safety,
      })

  run staleCompletionCannotCommitTest =
    init
      .then(apply(START_REQUESTED, 0, false))
      .then(apply(STOP_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 1, false))
      .expect(and {
        s.phase == STOPPING,
        s.operation == OP_STOP,
        s.active_token == 2,
        capture_lifecycle_safety,
      })

  run pauseResumeTest =
    init
      .then(apply(START_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 1, false))
      .then(apply(PAUSE_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 2, false))
      .then(apply(RESUME_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 3, false))
      .expect(and {
        s.phase == RECORDING,
        s.intends_capture,
        capture_lifecycle_safety,
      })

  run retryableRecoveryTest =
    init
      .then(apply(START_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 1, false))
      .then(apply(CAPTURE_INTERRUPTED, 0, true))
      .then(apply(RECOVERY_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 2, false))
      .expect(and {
        s.phase == RECORDING,
        s.intends_capture,
        capture_lifecycle_safety,
      })

  run fatalFailureFailsClosedTest =
    init
      .then(apply(START_REQUESTED, 0, false))
      .then(apply(OPERATION_FAILED, 1, false))
      .expect(and {
        s.phase == FAILED,
        not(s.intends_capture),
        s.has_failure,
        capture_lifecycle_safety,
      })

  run fatalFailureRequiresStopReconciliationTest =
    init
      .then(apply(START_REQUESTED, 0, false))
      .then(apply(OPERATION_FAILED, 1, false))
      .then(apply(START_REQUESTED, 0, false))
      .then(apply(STOP_REQUESTED, 0, false))
      .then(apply(OPERATION_SUCCEEDED, 2, false))
      .expect(and {
        s.phase == STOPPED,
        not(s.intends_capture),
        not(s.has_failure),
        capture_lifecycle_safety,
      })
}
