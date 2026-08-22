# Formal verification

This directory contains product-owned executable specifications for the
correctness-critical Sonus Auris client protocols. The shared Rust runner
tracked in DEN-565 will eventually discover `fm.toml`, execute the selected
backend, normalize ITF traces, and replay them through language adapters. The
product model remains next to the Dart implementation it describes.

## Application capture lifecycle

`capture_lifecycle.qnt` is the cross-platform application state model used by
the Flutter mobile and desktop entrypoints and mirrored byte-for-byte in the
pure-Rust desktop repository. Its stable states are `stopped`, `recording`,
`paused`, and `failed`; its transitional states are `starting`, `stopping`, and
`restarting`.

The production transition relation is
`lib/src/app/capture_lifecycle_machine.dart`. `AppController` interprets user
commands only through effects returned by that pure function, serializes
platform effects, and commits success/failure with the effect's generation
token. Environmental audio interruptions enter through explicit interruption
events and a fail-closed stop-before-recover effect. Mobile and desktop button
enablement comes from `CaptureCapabilities`, not from plugin booleans.

The aggregate `capture_lifecycle_safety` invariant checks:

1. every phase and operation remains in its finite domain;
2. transitional states have exactly one active operation token;
3. active tokens equal the monotonic generation and each transient phase has
   only its permitted operation kind;
4. stopped, recording, and paused intent remains coherent;
5. failure details exist exactly in the controlled `failed` state; and
6. stale completions stutter because their token cannot match the active one.

`test/capture_lifecycle_machine_test.dart` independently explores the reachable
production Dart state graph through four operation generations and checks
totality, determinism, invariant preservation, stale-result suppression, UI
capabilities, and recovery reachability.

The formal claim is deliberately bounded. It proves the abstract state machine
for the declared finite domains and 12-step Apalache executions; it does not
prove that Android, CoreAudio, storage, or a network provider cannot fail. Those
failures are environmental inputs and must map to `failed`, a retryable recovery
path, or a completed stop without bypassing the transition function.

Local capture-model commands:

```bash
QUINT_PACKAGE='@informalsystems/quint@0.32.0'
npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/capture_lifecycle.qnt
npx --yes --package="$QUINT_PACKAGE" quint test \
  formal/capture_lifecycle_test.qnt \
  --main=capture_lifecycle_test --match='.*Test$'
npx --yes --package="$QUINT_PACKAGE" quint run \
  formal/capture_lifecycle.qnt --main=capture_lifecycle \
  --max-samples=10000 --max-steps=24 \
  --invariant=capture_lifecycle_safety
npx --yes --package="$QUINT_PACKAGE" quint verify \
  formal/capture_lifecycle.qnt --main=capture_lifecycle \
  --max-steps=12 --invariant=capture_lifecycle_safety
```

## Rust presence WebSocket lifecycle

`rust_presence_lifecycle.qnt` models the fallback device-presence connection as
a generation-scoped protocol: idle, connecting, authenticating, connected,
waiting to retry, and explicitly closed. Every transport callback and timer is
tagged with the generation that created it. A callback from a replaced, failed,
or closed transport must stutter and therefore cannot authenticate, close, or
start heartbeats on the current connection.

The production refinement is the pure
`lib/src/services/rust_presence_lifecycle.dart` transition function interpreted
by `RustDevicePresenceClient`. It also gives reconnect timers a capped monotone
backoff, rejects presence data before authentication, and makes explicit close
terminal until a new configure event. Transport frames and server-provided
device identifiers are bounded before parsing or retention.

`test/rust_presence_lifecycle_test.dart` independently explores the bounded
Dart graph and checks totality, determinism, generation monotonicity, permitted
effect/phase pairs, retry bounds, and stale-event suppression. The fake-channel
client tests then exercise the async refinement with delayed readiness failures
and replacement credentials. Deterministic Quint traces cover the same races;
CI also simulates the aggregate `lifecycle_safety` invariant and requires
authenticated, retry-wait, and terminal-close witnesses.

The claim is safety, not network liveness: the model does not assume that DNS,
TLS, the API, or a mobile radio eventually succeeds. It establishes that any
late completion in the modeled finite lifecycle cannot regain authority over a
newer transport and that no heartbeat or presence side effect occurs in an
invalid phase.

```bash
QUINT_PACKAGE='@informalsystems/quint@0.32.0'
npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/rust_presence_lifecycle.qnt
npx --yes --package="$QUINT_PACKAGE" quint test \
  formal/rust_presence_lifecycle_test.qnt \
  --main=rust_presence_lifecycle_test --match='.*Test$'
npx --yes --package="$QUINT_PACKAGE" quint run \
  formal/rust_presence_lifecycle.qnt --main=rust_presence_lifecycle \
  --max-samples=10000 --max-steps=25 --invariant=lifecycle_safety \
  --witnesses authenticated_connection_reached retry_wait_reached terminal_close_reached
```

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
