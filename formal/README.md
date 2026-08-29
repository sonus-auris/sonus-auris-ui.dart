# Formal verification

This directory contains product-owned executable specifications for the
correctness-critical Sonus Auris client protocols. The shared Rust runner
tracked in DEN-565 will eventually discover `fm.toml`, execute the selected
backend, normalize ITF traces, and replay them through language adapters. The
product model remains next to the Dart implementation it describes.

## First model: encrypted segment lifecycle

`segment_lifecycle.qnt` models one rolling audio segment through:

```text
pending -> uploading -> uploaded
                 \-> failed -> uploading (retry)

local plaintext
  -> encrypted network body
  -> one logical remote object
  -> verified remote acknowledgement
  -> optional permanent copy
  -> tombstone-before-delete retention
  -> local metadata convergence after restart
```

The finite model keeps two upload generations, direct-S3 and backend-mediated
completion, two derived local artifacts, one logical remote object, and every
retention-journal stage. This is enough to exercise retry identity, stale
results, partial remote success, encryption failure, process restart, the fixed
plaintext deadline, free-space policy, and crashes during deletion.

### Source correspondence

| Model concept | Dart implementation |
| --- | --- |
| persisted upload status and remote/local metadata | `lib/src/models/recording_segment.dart` |
| single-flight upload drain and retry-visible `uploading` | `lib/src/app/app_controller.dart` |
| direct S3 encryption-before-PUT and stable object key | `lib/src/services/s3_storage_client.dart` |
| backend encryption, presign, PUT, and completion acknowledgement | `lib/src/services/sound_recorder_backend_client.dart` |
| atomic index, artifact inventory, retention journal, and restart replay | `lib/src/services/segment_index.dart` |
| fixed 100-hour plaintext deadline | `lib/src/retention/local_retention_policy.dart` |

## Checked safety properties

The aggregate invariant `segment_lifecycle_safety` checks:

1. network audio is never represented as sent unless it was sealed on-device;
2. `uploaded` and permanent-copy states require a verified remote key and an
   acknowledged upload generation;
3. retries preserve one logical remote-object identity;
4. a backend PUT without completion, or a direct sidecar failure, cannot publish
   the segment as uploaded;
5. volatile upload state may disappear on restart without losing persisted
   acknowledgement or moving the retention deadline;
6. derived artifacts are deleted before canonical audio, and index/tombstone
   stages remain crash-consistent;
7. free-space deletion requires an uploaded or permanent copy;
8. unbacked plaintext deleted at the retention deadline becomes an explicit
   failed/error state rather than a false success;
9. logical time cannot progress beyond the fixed deadline while plaintext
   remains; crossing the boundary first persists the deletion tombstone;
10. active, sealed, acknowledged, and stale upload generations remain coherent.

`segment_lifecycle_test.qnt` adds deterministic traces for direct and backend
success, blocked plaintext egress, encryption failure, backend completion,
sidecar partial failure and retry, restart-visible upload retry, stale-result
suppression, free-space deletion, deadline deletion, and crashes at two journal
stages.

## Rust presence lifecycle model

`rust_presence_lifecycle.qnt` models the Flutter client's secondary Rust API
WebSocket as an explicit generation-scoped state machine. It corresponds to
`lib/src/services/rust_presence_lifecycle.dart` and the transport owner in
`lib/src/services/rust_device_presence_client.dart`.

Together with the pure Dart transition tests, the aggregate `lifecycle_safety`
invariant and eight named traces check that:

1. readiness, messages, failures, heartbeats, and retry timers from a stale or
   missing generation stutter;
2. authentication and heartbeat effects occur only in their named phases;
3. a failure invalidates the active generation before transport teardown can
   produce another callback;
4. retry delay is capped in Dart and the retry budget is exactly seven attempts
   in both Dart and Quint;
5. exhausted and closed states cannot reopen from a timer or transport event;
   only explicit configuration starts a new generation; and
6. connected presence cannot be accepted before authentication.

The production tests use `fake_async` to advance every backoff interval without
wall-clock sleeps and prove that retry exhaustion and close leave zero timers.
The snapshot surface uses RxDart `BehaviorSubject` only for the useful bounded
semantic it provides: a late subscriber receives one current state containing
at most 256 normalized identifiers. Lifecycle instrumentation is payload-free
and observer failures cannot affect the connection or recording.

This model covers the platform-specific Flutter fallback named in DEN-3888. It
does not claim that the desktop Rust application has an equivalent fallback;
the Rust API/server presence transports remain separate DEN-3888 work and are
linked from that issue.

## Exact bounds and claim strength

This is a finite design model, not yet a proof that every Dart execution refines
the model. CI records the exact bounds in `fm.toml`:

- one segment;
- two upload generations;
- one logical remote object;
- two derived local artifacts;
- two upload modes;
- four retention-journal stages;
- a four-tick fixed deadline representing the product's 100-hour ceiling;
- logical time through seven.

The logical clock is an abstraction. The model treats retention enforcement as
urgent at the deadline: the journal is persisted at the boundary and logical
time cannot progress until local deletion converges. This checks that retries,
offline state, provider failures, and restarts cannot extend the deadline. It
does not establish a real-device upper bound for filesystem scheduling latency.

- `quint test` validates named deterministic traces and exports ITF artifacts.
- `quint run` performs randomized exploration, checks the aggregate invariant,
  and requires important states to be reachable.
- `quint verify` uses Apalache for exhaustive bounded checking on pushes to
  `main`, scheduled runs, and manual dispatch.
- The future Dart adapter will inject clock, filesystem, encryptor, network,
  identity, and crash points, then compare a canonical abstract state after
  each ITF action.
- Unbounded liveness is not claimed. Crash recovery requires the explicit
  assumption that the app eventually restarts and is allowed to complete the
  retained journal.

## Local commands

```bash
QUINT_PACKAGE='@informalsystems/quint@0.32.0'

npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/segment_lifecycle.qnt
npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/segment_lifecycle_test.qnt
npx --yes --package="$QUINT_PACKAGE" quint test \
  formal/segment_lifecycle_test.qnt \
  --main=segment_lifecycle_test \
  --match='.*Test$'
npx --yes --package="$QUINT_PACKAGE" quint run \
  formal/segment_lifecycle.qnt \
  --main=segment_lifecycle \
  --max-samples=10000 \
  --max-steps=35 \
  --invariant=segment_lifecycle_safety \
  --witnesses \
    direct_upload_reached \
    partial_remote_without_ack_reached \
    retry_generation_reached \
    retention_tombstone_reached \
    unbacked_retention_failure_reached

npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/rust_presence_lifecycle.qnt
npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/rust_presence_lifecycle_test.qnt
npx --yes --package="$QUINT_PACKAGE" quint test \
  formal/rust_presence_lifecycle_test.qnt \
  --main=rust_presence_lifecycle_test \
  --match='.*Test$'
npx --yes --package="$QUINT_PACKAGE" quint run \
  formal/rust_presence_lifecycle.qnt \
  --main=rust_presence_lifecycle \
  --max-samples=10000 \
  --max-steps=24 \
  --invariant=lifecycle_safety \
  --witnesses \
    authenticated_connection_reached \
    retry_wait_reached \
    terminal_close_reached
```

Java 17 or newer is required for bounded `quint verify`.

## Next implementation slice

Extract deterministic transition seams from the existing Dart services without
moving policy into a second implementation. Add a JSON-lines adapter that:

1. accepts the versioned DEN-565 action protocol;
2. injects logical time, stable IDs, filesystem outcomes, encryption outcomes,
   HTTP responses, and crash points;
3. exposes only canonical segment, remote-acknowledgement, and tombstone state;
4. replays generated ITF traces; and
5. turns every mismatch into a minimized Dart regression test.

TypeScript implementations of the same business protocol should consume the
same trace corpus rather than translating the model into framework-specific
state graphs.
