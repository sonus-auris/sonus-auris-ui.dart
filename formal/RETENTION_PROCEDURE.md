# Formal-methods procedure: local plaintext retention

The rolling-audio client may keep local plaintext for no more than the configured ceiling (100 hours by default, or less under storage pressure). Deletion spans a filesystem, metadata index, derived-artifact inventory, and crash-replay journal, so a process stop between writes must not resurrect a local path, strand sensitive companions, or hide an unbacked expiry.

## Claim boundary

`formal/retention_journal_model.py` is a finite abstraction of the retention tombstone protocol. It explores backed-up and unbacked segments, every abstract action through the configured depth, and each reachable crash boundary. Dart crash-injection tests remain the production refinement gate. It does not prove OS filesystem durability, forensic erasure, cloud backup correctness, or unregistered artifacts.

## Model-to-code correspondence

| Abstract step | Production responsibility |
|---|---|
| `tombstone` | persist the versioned tombstone before destructive work |
| `delete` | remove audio, sidecars, partials, and registered derived artifacts |
| `persist_index` | clear the local path and surface unbacked expiry |
| `clear_journal` | complete only after artifacts and metadata converge |
| `recover` | `loadSegments` replays unfinished tombstones idempotently |
| `crash` | discards the in-memory `SegmentIndex`, reloading it from the persisted index; the tombstone and the on-disk deletion survive. Refined by `RetentionMutationStage` hooks and crash-injection tests |

## Required invariants

1. Deleted artifacts with a stale local index entry always retain a durable tombstone.
2. Clearing a tombstone implies artifacts are absent and metadata no longer advertises plaintext.
3. Unbacked expiry is visible as failure, never successful backup.
4. Replaying any reachable journaled state converges artifacts, metadata, and journal.
5. Recovery is idempotent after convergence.

## Change procedure

1. Register each new plaintext or derived-sensitive artifact with the retention unit before another worker can depend on it.
2. Preserve ordering: tombstone flush, artifact deletion, index flush, tombstone completion.
3. Extend the abstract action set and Dart crash hooks together when adding a durable phase.
4. Add a production test that stops after each durable mutation and reopens through normal startup.
5. Run:

   ```bash
   python3 formal/retention_journal_model.py
   printf '%s\n' '{"op":"replay","backed_up":false,"events":["tombstone","delete","crash","recover"]}' \
     | python3 formal/retention_journal_model.py --json-stdin
   flutter test
   ```

6. Review path containment separately; the journal must never authorize deletion outside app-owned storage.
7. Treat any increase beyond the 100-hour product ceiling as a privacy-policy and architecture change.

## Relationship to the Quint model

The existing Quint `segment_lifecycle` model remains the end-to-end encrypted-upload/retention specification. This smaller executable model isolates persisted tombstone ordering and gives CI and the shared `fmctl` JSON-lines convention a deterministic crash-replay oracle. It complements rather than replaces Quint/Apalache.

## Explicitly out of scope

This procedure does not claim forensic erasure, hidden-copy prevention in third-party plugins, encryption-key lifecycle, or backend/cloud retention.
