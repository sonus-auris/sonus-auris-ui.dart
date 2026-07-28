// Bounded model of local plaintext -> encrypted upload -> verified remote
// acknowledgement -> crash-safe retention for one Sonus Auris segment.
module segment_lifecycle {
  type State = {
    now: int,
    retention_deadline: int,
    gate_allowed: bool,
    key_available: bool,
    mode: int,
    status: int,
    next_generation: int,
    active_generation: int,
    sealed_generation: int,
    acknowledged_generation: int,
    network_sent: bool,
    network_sent_encrypted: bool,
    remote_objects: Set[int],
    remote_key_present: bool,
    permanent_copy_present: bool,
    audio_present: bool,
    index_local_present: bool,
    derived_artifacts: Set[int],
    tombstone_stage: int,
    tombstone_reason: int,
    retention_expired_before_backup: bool,
    retention_error_recorded: bool,
  }

  pure val MODE_NONE = 0
  pure val MODE_DIRECT_S3 = 1
  pure val MODE_BACKEND = 2

  pure val STATUS_PENDING = 0
  pure val STATUS_UPLOADING = 1
  pure val STATUS_UPLOADED = 2
  pure val STATUS_FAILED = 3
  pure val STATUS_LOCAL_ONLY = 4

  pure val TOMBSTONE_NONE = 0
  pure val TOMBSTONE_PERSISTED = 1
  pure val TOMBSTONE_ARTIFACTS_DELETED = 2
  pure val TOMBSTONE_INDEX_PERSISTED = 3

  pure val REASON_NONE = 0
  pure val REASON_RETENTION = 1
  pure val REASON_FREE_SPACE = 2

  // Four logical ticks represent the immutable product maximum of 100 hours.
  pure val RETENTION_DEADLINE = 4
  pure val MAX_TIME = 7
  pure val MAX_GENERATION = 2
  pure val LOGICAL_REMOTE_OBJECT = 1
  pure val DERIVED_ARTIFACTS: Set[int] = Set(1, 2)
  pure val BOOLS: Set[bool] = Set(true, false)
  pure val UPLOAD_MODES: Set[int] = Set(MODE_DIRECT_S3, MODE_BACKEND)

  var s: State

  pure def valid_mode(candidate: int): bool =
    Set(MODE_NONE, MODE_DIRECT_S3, MODE_BACKEND).contains(candidate)

  pure def valid_status(candidate: int): bool =
    Set(
      STATUS_PENDING,
      STATUS_UPLOADING,
      STATUS_UPLOADED,
      STATUS_FAILED,
      STATUS_LOCAL_ONLY
    ).contains(candidate)

  pure def retryable(candidate: int): bool =
    Set(STATUS_PENDING, STATUS_UPLOADING, STATUS_FAILED).contains(candidate)

  pure def backed_up(snapshot: State): bool =
    snapshot.remote_key_present or snapshot.permanent_copy_present

  action init: bool = {
    s' = {
      now: 0,
      retention_deadline: RETENTION_DEADLINE,
      gate_allowed: true,
      key_available: true,
      mode: MODE_NONE,
      status: STATUS_PENDING,
      next_generation: 1,
      active_generation: 0,
      sealed_generation: 0,
      acknowledged_generation: 0,
      network_sent: false,
      network_sent_encrypted: false,
      remote_objects: Set(),
      remote_key_present: false,
      permanent_copy_present: false,
      audio_present: true,
      index_local_present: true,
      derived_artifacts: DERIVED_ARTIFACTS,
      tombstone_stage: TOMBSTONE_NONE,
      tombstone_reason: REASON_NONE,
      retention_expired_before_backup: false,
      retention_error_recorded: false,
    }
  }

  action set_gate(allowed: bool): bool = all {
    BOOLS.contains(allowed),
    s' = { ...s, gate_allowed: allowed },
  }

  action set_key_available(available: bool): bool = all {
    BOOLS.contains(available),
    s' = { ...s, key_available: available },
  }

  // `uploading` is persisted before encryption and network I/O, so it remains
  // retryable after a process restart.
  action begin_upload(upload_mode: int): bool = all {
    UPLOAD_MODES.contains(upload_mode),
    s.audio_present,
    s.index_local_present,
    s.tombstone_stage == TOMBSTONE_NONE,
    s.gate_allowed,
    s.active_generation == 0,
    retryable(s.status),
    s.next_generation <= MAX_GENERATION,
    s' = {
      ...s,
      mode: upload_mode,
      status: STATUS_UPLOADING,
      active_generation: s.next_generation,
      next_generation: s.next_generation + 1,
      sealed_generation: 0,
      network_sent: false,
      network_sent_encrypted: false,
    },
  }

  action seal_active: bool = all {
    s.active_generation > 0,
    s.key_available,
    s.audio_present,
    s.tombstone_stage == TOMBSTONE_NONE,
    s' = { ...s, sealed_generation: s.active_generation },
  }

  action encryption_failure: bool = all {
    s.active_generation > 0,
    s.sealed_generation == 0,
    s' = {
      ...s,
      mode: MODE_NONE,
      status: STATUS_FAILED,
      active_generation: 0,
      sealed_generation: 0,
      network_sent: false,
      network_sent_encrypted: false,
    },
  }

  // The only egress transition requires the active generation to be sealed.
  // Every retry addresses one stable logical remote object.
  action send_audio_ciphertext: bool = all {
    s.active_generation > 0,
    s.sealed_generation == s.active_generation,
    s.gate_allowed,
    s.audio_present,
    s.tombstone_stage == TOMBSTONE_NONE,
    s' = {
      ...s,
      network_sent: true,
      network_sent_encrypted: true,
      remote_objects: s.remote_objects.union(Set(LOGICAL_REMOTE_OBJECT)),
    },
  }

  action direct_upload_complete: bool = all {
    s.mode == MODE_DIRECT_S3,
    s.active_generation > 0,
    s.network_sent,
    s.network_sent_encrypted,
    s.remote_objects.contains(LOGICAL_REMOTE_OBJECT),
    s' = {
      ...s,
      mode: MODE_NONE,
      status: STATUS_UPLOADED,
      acknowledged_generation: s.active_generation,
      active_generation: 0,
      sealed_generation: 0,
      remote_key_present: true,
    },
  }

  // A direct audio PUT whose sidecar fails leaves a partial remote object, but
  // never publishes the segment as uploaded.
  action direct_sidecar_failure: bool = all {
    s.mode == MODE_DIRECT_S3,
    s.active_generation > 0,
    s.network_sent,
    s.remote_objects.contains(LOGICAL_REMOTE_OBJECT),
    s' = {
      ...s,
      mode: MODE_NONE,
      status: STATUS_FAILED,
      active_generation: 0,
      sealed_generation: 0,
      remote_key_present: false,
    },
  }

  // Backend PUT success is not acknowledgement; completion must return a key.
  action backend_complete: bool = all {
    s.mode == MODE_BACKEND,
    s.active_generation > 0,
    s.network_sent,
    s.network_sent_encrypted,
    s.remote_objects.contains(LOGICAL_REMOTE_OBJECT),
    s' = {
      ...s,
      mode: MODE_NONE,
      status: STATUS_UPLOADED,
      acknowledged_generation: s.active_generation,
      active_generation: 0,
      sealed_generation: 0,
      remote_key_present: true,
    },
  }

  action backend_complete_failure: bool = all {
    s.mode == MODE_BACKEND,
    s.active_generation > 0,
    s.network_sent,
    s' = {
      ...s,
      mode: MODE_NONE,
      status: STATUS_FAILED,
      active_generation: 0,
      sealed_generation: 0,
      remote_key_present: false,
    },
  }

  action mark_permanent_copy: bool = all {
    s.remote_key_present,
    s.status == STATUS_UPLOADED,
    s' = { ...s, permanent_copy_present: true },
  }

  // Restart clears volatile attempt state and preserves persisted protocol state.
  action restart: bool = {
    s' = {
      ...s,
      mode: MODE_NONE,
      active_generation: 0,
      sealed_generation: 0,
      network_sent: false,
      network_sent_encrypted: false,
    }
  }

  action stale_success(generation: int): bool = all {
    generation >= 1,
    generation < s.next_generation,
    generation != s.active_generation,
    or {
      s.active_generation > generation,
      s.acknowledged_generation > generation,
    },
    s' = s,
  }

  action stale_failure(generation: int): bool = all {
    generation >= 1,
    generation < s.next_generation,
    generation != s.active_generation,
    or {
      s.active_generation > generation,
      s.acknowledged_generation > generation,
    },
    s' = s,
  }

  // Time advances before the deadline, or after local plaintext is gone.
  action tick_without_retention_boundary: bool = all {
    s.now < MAX_TIME,
    or {
      s.now + 1 < s.retention_deadline,
      not(s.index_local_present),
    },
    s' = { ...s, now: s.now + 1 },
  }

  // Crossing the deadline first persists the crash-recovery journal. Logical
  // time cannot advance beyond this boundary until deletion converges.
  action tick_to_retention_deadline: bool = all {
    s.now < MAX_TIME,
    s.now + 1 >= s.retention_deadline,
    s.index_local_present,
    s.tombstone_stage == TOMBSTONE_NONE,
    s' = {
      ...s,
      now: s.now + 1,
      tombstone_stage: TOMBSTONE_PERSISTED,
      tombstone_reason: REASON_RETENTION,
      retention_expired_before_backup: not(backed_up(s)),
    },
  }

  action begin_free_space_deletion: bool = all {
    s.index_local_present,
    s.audio_present,
    s.tombstone_stage == TOMBSTONE_NONE,
    backed_up(s),
    s' = {
      ...s,
      tombstone_stage: TOMBSTONE_PERSISTED,
      tombstone_reason: REASON_FREE_SPACE,
      retention_expired_before_backup: false,
    },
  }

  action delete_derived_artifact(artifact: int): bool = all {
    DERIVED_ARTIFACTS.contains(artifact),
    s.tombstone_stage == TOMBSTONE_PERSISTED,
    s.derived_artifacts.contains(artifact),
    s' = {
      ...s,
      derived_artifacts: s.derived_artifacts.filter(
        artifact_id => artifact_id != artifact
      ),
    },
  }

  // Canonical audio is deleted after every derived local artifact.
  action delete_audio_last: bool = all {
    s.tombstone_stage == TOMBSTONE_PERSISTED,
    s.derived_artifacts.size() == 0,
    s.audio_present,
    s' = {
      ...s,
      audio_present: false,
      tombstone_stage: TOMBSTONE_ARTIFACTS_DELETED,
    },
  }

  action persist_deleted_index: bool = all {
    s.tombstone_stage == TOMBSTONE_ARTIFACTS_DELETED,
    s.index_local_present,
    s' = {
      ...s,
      mode: MODE_NONE,
      status: if (s.retention_expired_before_backup)
        STATUS_FAILED
      else
        s.status,
      active_generation: 0,
      sealed_generation: 0,
      network_sent: false,
      network_sent_encrypted: false,
      index_local_present: false,
      tombstone_stage: TOMBSTONE_INDEX_PERSISTED,
      retention_error_recorded: s.retention_error_recorded
        or s.retention_expired_before_backup,
    },
  }

  action clear_completed_tombstone: bool = all {
    s.tombstone_stage == TOMBSTONE_INDEX_PERSISTED,
    not(s.index_local_present),
    not(s.audio_present),
    s.derived_artifacts.size() == 0,
    s' = {
      ...s,
      tombstone_stage: TOMBSTONE_NONE,
      tombstone_reason: REASON_NONE,
      retention_expired_before_backup: false,
    },
  }

  action idle: bool = s' = s

  action step: bool = {
    nondet upload_mode = UPLOAD_MODES.oneOf()
    nondet flag = BOOLS.oneOf()
    nondet artifact = DERIVED_ARTIFACTS.oneOf()
    nondet generation = Set(1, 2).oneOf()
    any {
      set_gate(flag),
      set_key_available(flag),
      begin_upload(upload_mode),
      seal_active,
      encryption_failure,
      send_audio_ciphertext,
      direct_upload_complete,
      direct_sidecar_failure,
      backend_complete,
      backend_complete_failure,
      mark_permanent_copy,
      restart,
      stale_success(generation),
      stale_failure(generation),
      tick_without_retention_boundary,
      tick_to_retention_deadline,
      begin_free_space_deletion,
      delete_derived_artifact(artifact),
      delete_audio_last,
      persist_deleted_index,
      clear_completed_tombstone,
      idle,
    }
  }

  val domain_bounds = and {
    s.now >= 0,
    s.now <= MAX_TIME,
    s.retention_deadline == RETENTION_DEADLINE,
    valid_mode(s.mode),
    valid_status(s.status),
    s.next_generation >= 1,
    s.next_generation <= MAX_GENERATION + 1,
    s.active_generation >= 0,
    s.active_generation <= MAX_GENERATION,
    s.sealed_generation >= 0,
    s.sealed_generation <= MAX_GENERATION,
    s.acknowledged_generation >= 0,
    s.acknowledged_generation <= MAX_GENERATION,
    s.active_generation < s.next_generation,
    s.sealed_generation == 0 or s.sealed_generation == s.active_generation,
    s.acknowledged_generation < s.next_generation,
    s.remote_objects.size() <= 1,
    s.remote_objects.forall(object_id => object_id == LOGICAL_REMOTE_OBJECT),
    s.derived_artifacts.forall(artifact => DERIVED_ARTIFACTS.contains(artifact)),
    s.tombstone_stage >= TOMBSTONE_NONE,
    s.tombstone_stage <= TOMBSTONE_INDEX_PERSISTED,
    Set(REASON_NONE, REASON_RETENTION, REASON_FREE_SPACE).contains(
      s.tombstone_reason
    ),
  }

  val no_plaintext_egress =
    not(s.network_sent) or s.network_sent_encrypted

  val uploaded_requires_verified_remote =
    s.status != STATUS_UPLOADED or and {
      s.remote_key_present,
      s.acknowledged_generation > 0,
      s.remote_objects.contains(LOGICAL_REMOTE_OBJECT),
    }

  val permanent_copy_requires_verified_upload =
    not(s.permanent_copy_present) or and {
      s.remote_key_present,
      s.acknowledged_generation > 0,
    }

  val deletion_is_crash_consistent = and {
    s.audio_present or s.derived_artifacts.size() == 0,
    s.index_local_present or not(s.audio_present),
    (s.tombstone_stage >= TOMBSTONE_ARTIFACTS_DELETED).implies(and {
      not(s.audio_present),
      s.derived_artifacts.size() == 0,
    }),
    (s.tombstone_stage >= TOMBSTONE_INDEX_PERSISTED).implies(
      not(s.index_local_present)
    ),
    (s.tombstone_stage == TOMBSTONE_NONE).implies(and {
      s.tombstone_reason == REASON_NONE,
      not(s.index_local_present).implies(and {
        not(s.audio_present),
        s.derived_artifacts.size() == 0,
      }),
    }),
    (s.tombstone_stage != TOMBSTONE_NONE).implies(
      s.tombstone_reason != REASON_NONE
    ),
  }

  val free_space_deletion_requires_backup =
    (s.tombstone_reason == REASON_FREE_SPACE).implies(backed_up(s))

  val expired_unbacked_plaintext_is_recorded =
    and {
      s.tombstone_stage >= TOMBSTONE_INDEX_PERSISTED,
      s.retention_expired_before_backup,
    }.implies(and {
      s.status == STATUS_FAILED,
      s.retention_error_recorded,
    })

  val hard_retention_ceiling = and {
    s.now <= s.retention_deadline or not(s.audio_present),
    s.now < s.retention_deadline
      or not(s.index_local_present)
      or s.tombstone_stage != TOMBSTONE_NONE,
  }

  val generation_binding = and {
    not(s.remote_key_present) or s.acknowledged_generation > 0,
    s.acknowledged_generation == 0 or s.remote_key_present,
    s.active_generation == 0 or s.status == STATUS_UPLOADING,
  }

  val segment_lifecycle_safety = and {
    domain_bounds,
    no_plaintext_egress,
    uploaded_requires_verified_remote,
    permanent_copy_requires_verified_upload,
    s.remote_objects.size() <= 1,
    deletion_is_crash_consistent,
    free_space_deletion_requires_backup,
    expired_unbacked_plaintext_is_recorded,
    hard_retention_ceiling,
    generation_binding,
  }

  val direct_upload_reached = and {
    s.status == STATUS_UPLOADED,
    s.acknowledged_generation > 0,
  }
  val partial_remote_without_ack_reached = and {
    s.remote_objects.contains(LOGICAL_REMOTE_OBJECT),
    not(s.remote_key_present),
  }
  val retry_generation_reached = s.next_generation == MAX_GENERATION + 1
  val retention_tombstone_reached =
    s.tombstone_reason == REASON_RETENTION
  val unbacked_retention_failure_reached = and {
    s.retention_error_recorded,
    s.status == STATUS_FAILED,
    not(s.index_local_present),
  }
}
