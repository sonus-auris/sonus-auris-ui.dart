module segment_lifecycle_test {
  import segment_lifecycle.* from "./segment_lifecycle"

  run directEncryptedUploadTest =
    init
      .then(begin_upload(MODE_DIRECT_S3))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .then(direct_upload_complete)
      .expect(and {
        s.status == STATUS_UPLOADED,
        s.remote_key_present,
        s.acknowledged_generation == 1,
        s.remote_objects == Set(LOGICAL_REMOTE_OBJECT),
        segment_lifecycle_safety,
      })

  run plaintextEgressIsBlockedTest =
    init
      .then(begin_upload(MODE_DIRECT_S3))
      .then(send_audio_ciphertext)
      .fail()

  run encryptionFailureFailsClosedTest =
    init
      .then(begin_upload(MODE_BACKEND))
      .then(encryption_failure)
      .expect(and {
        s.status == STATUS_FAILED,
        not(s.network_sent),
        s.remote_objects.size() == 0,
        segment_lifecycle_safety,
      })

  run backendPutRequiresCompletionTest =
    init
      .then(begin_upload(MODE_BACKEND))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .expect(and {
        s.status == STATUS_UPLOADING,
        not(s.remote_key_present),
        s.remote_objects == Set(LOGICAL_REMOTE_OBJECT),
        partial_remote_without_ack_reached,
        segment_lifecycle_safety,
      })

  run backendCompletionAcknowledgesUploadTest =
    init
      .then(begin_upload(MODE_BACKEND))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .then(backend_complete)
      .expect(and {
        s.status == STATUS_UPLOADED,
        s.remote_key_present,
        s.acknowledged_generation == 1,
        segment_lifecycle_safety,
      })

  run sidecarFailureRetryUsesOneRemoteObjectTest =
    init
      .then(begin_upload(MODE_DIRECT_S3))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .then(direct_sidecar_failure)
      .then(begin_upload(MODE_DIRECT_S3))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .then(direct_upload_complete)
      .expect(and {
        s.status == STATUS_UPLOADED,
        s.acknowledged_generation == 2,
        s.remote_objects == Set(LOGICAL_REMOTE_OBJECT),
        s.remote_objects.size() == 1,
        segment_lifecycle_safety,
      })

  run restartVisibleUploadingIsRetryableTest =
    init
      .then(begin_upload(MODE_BACKEND))
      .then(seal_active)
      .then(restart)
      .then(begin_upload(MODE_BACKEND))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .then(backend_complete)
      .expect(and {
        s.status == STATUS_UPLOADED,
        s.acknowledged_generation == 2,
        s.remote_objects.size() == 1,
        segment_lifecycle_safety,
      })

  run staleFailureCannotRegressNewerSuccessTest =
    init
      .then(begin_upload(MODE_DIRECT_S3))
      .then(encryption_failure)
      .then(begin_upload(MODE_DIRECT_S3))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .then(direct_upload_complete)
      .then(stale_failure(1))
      .expect(and {
        s.status == STATUS_UPLOADED,
        s.acknowledged_generation == 2,
        s.remote_key_present,
        segment_lifecycle_safety,
      })

  run freeSpaceCannotDeleteUnbackedPlaintextTest =
    init
      .then(begin_free_space_deletion)
      .fail()

  run freeSpaceDeletionAfterUploadIsCrashSafeTest =
    init
      .then(begin_upload(MODE_DIRECT_S3))
      .then(seal_active)
      .then(send_audio_ciphertext)
      .then(direct_upload_complete)
      .then(begin_free_space_deletion)
      .then(delete_derived_artifact(1))
      .then(restart)
      .then(delete_derived_artifact(2))
      .then(delete_audio_last)
      .then(persist_deleted_index)
      .then(clear_completed_tombstone)
      .expect(and {
        s.status == STATUS_UPLOADED,
        s.remote_key_present,
        not(s.audio_present),
        not(s.index_local_present),
        s.tombstone_stage == TOMBSTONE_NONE,
        segment_lifecycle_safety,
      })

  run retentionDeadlineDeletesUnbackedPlaintextTest =
    init
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_to_retention_deadline)
      .then(delete_derived_artifact(1))
      .then(delete_derived_artifact(2))
      .then(delete_audio_last)
      .then(persist_deleted_index)
      .then(clear_completed_tombstone)
      .expect(and {
        s.now == RETENTION_DEADLINE,
        s.status == STATUS_FAILED,
        s.retention_error_recorded,
        not(s.audio_present),
        not(s.index_local_present),
        segment_lifecycle_safety,
      })

  run crashAfterRetentionTombstoneReplaysTest =
    init
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_to_retention_deadline)
      .then(restart)
      .then(delete_derived_artifact(1))
      .then(delete_derived_artifact(2))
      .then(delete_audio_last)
      .then(persist_deleted_index)
      .then(clear_completed_tombstone)
      .expect(and {
        s.retention_error_recorded,
        not(s.audio_present),
        not(s.index_local_present),
        segment_lifecycle_safety,
      })

  run crashAfterArtifactDeletionReplaysTest =
    init
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_to_retention_deadline)
      .then(delete_derived_artifact(1))
      .then(delete_derived_artifact(2))
      .then(delete_audio_last)
      .then(restart)
      .then(persist_deleted_index)
      .then(clear_completed_tombstone)
      .expect(and {
        s.retention_error_recorded,
        s.tombstone_stage == TOMBSTONE_NONE,
        not(s.audio_present),
        segment_lifecycle_safety,
      })

  run timeCannotPassDeadlineWithPendingPlaintextDeletionTest =
    init
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_without_retention_boundary)
      .then(tick_to_retention_deadline)
      .then(tick_without_retention_boundary)
      .fail()
}
