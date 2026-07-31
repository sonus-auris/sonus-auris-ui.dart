# Retention worker coordination

Linear: DEN-250

## Safety property

Account deletion or recording-consent revocation must not race an active
recorder, uploader, analyzer, or exporter in a way that recreates app-private
plaintext after cleanup.

`RetentionWorkerCoordinator` provides the shared destructive barrier:

1. reject new worker admission synchronously;
2. increment the retention generation so every outstanding lease is stale;
3. wait for all tracked worker callbacks to drain;
4. delete app-private local state;
5. remain closed, or admit a new generation only after explicit consent.

Account deletion is permanent. Consent revocation may be followed by
`resumeAfterConsent` only after cleanup has completed and the product has
recorded a new consent grant.

A failed destructive clear never reopens worker admission. Account deletion
remains permanently sealed while cleanup is retried until `localStateCleared` is
true. After a successful clear, repeated deletion calls are idempotent.

## Worker contract

Every retention-sensitive worker must run through `runWorker` and keep all of its
asynchronous local work inside that callback. Before each durable write, it must
call `lease.throwIfRevoked`, `lease.commit`, or `lease.commitAsync`.

Workers must not launch detached writes that outlive the callback. The barrier
can drain only work it can account for.

Expected mappings:

| Worker | Coordinated work |
|---|---|
| recorder | segment path creation, `.part` writes, finalization, index upsert |
| uploader | local reads and upload-status/index commits |
| analyzer | FFT sidecars, transcripts, scratch/cache registration |
| exporter | local reads and temporary assembled output |
| destructive transition | consent-revocation cleanup or account deletion |

## Ordering rationale

Invalidation happens before waiting. Reversing that order would leave a window
where a new worker could enter while deletion was waiting for older work.

Cleanup happens after draining. Therefore a worker admitted before invalidation
cannot recreate a path after cleanup: it either observes a stale lease and stops,
or finishes before cleanup deletes its output.

Cleanup success is tracked separately from permanent sealing. Conflating the two
would make a failed account-deletion clear look complete and suppress the retry
needed to remove residual local state.

## Current integration boundary

This change introduces and exhaustively tests the coordination primitive. It does
not yet claim that every existing worker is wired through it. Controller/service
wiring must be performed as focused follow-up changes so recorder, uploader,
analyzer, exporter, account-deletion, and consent-revocation behavior can each be
reviewed and fault-injected independently.

Until that wiring is complete, DEN-250 remains In Progress.

## Required integration tests

For each wired worker, add a deterministic test that pauses immediately before a
durable write, begins consent revocation/account deletion, releases the worker,
and proves:

- new work is rejected;
- the stale worker cannot report a durable success;
- cleanup runs after the worker drains;
- no path, inventory entry, index row, token, or queued retry is recreated;
- account deletion cannot be resumed;
- failed cleanup remains sealed and can be retried;
- a new consent generation can record only after cleanup and explicit regrant.
