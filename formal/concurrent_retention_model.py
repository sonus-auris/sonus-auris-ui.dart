#!/usr/bin/env python3
"""Interleaving checker for the upload-drain / retention race (AUDIT F1).

AUDIT-2026-08-22 F1 states the defect in prose:

    Both `_drainUploads` and `_enforceRetention` are kicked off from
    `_onSegmentClosed` and both do read-modify-write of the *whole* segment
    index. `_replaceSegment` reads the list, awaits, then writes -- unguarded
    check-then-act. If retention's `saveSegments` lands after a successful
    upload it overwrites the freshly persisted `remoteKey` while the local file
    is already deleted.

Prose is not a counterexample. This module enumerates every interleaving of the
two workers over one segment and either exhibits the losing trace or proves it
absent, for four different repair configurations. The result is a table saying
which repairs actually close the race -- which matters, because the obvious one
does not.

Why a separate model from `upload_generation_model.py`: that one checks a
*sequential* state machine, one caller at a time. Nothing in it can express two
workers holding stale snapshots of the same index. `segment_lifecycle.qnt`
cannot either -- it models a single segment's lifecycle, not concurrent writers
over the persisted list. This is the gap where the CRITICAL finding lives.

Scope, stated plainly: one segment, two workers, three steps each. That is the
smallest system that exhibits lost-update, and a bug needing two segments or a
third worker is out of scope here. Cloud-retention expiry is deliberately
excluded so that "the remote key disappeared" has exactly one possible cause.

Every check raises explicitly rather than using `assert`, so running this under
`python3 -O` cannot silently disable the model.
"""

from __future__ import annotations

import argparse
import itertools
import json
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterator, NoReturn

# --------------------------------------------------------------------------
# Repair configurations
# --------------------------------------------------------------------------
#
# UNGUARDED         the original defect: raw copyWith, no lock, and both
#                   workers writing a whole list they snapshotted before an
#                   await.
# GENERATION_GUARD  route every upload transition through the state machine's
#                   begin/succeed/fail, which is what F1's text prescribes --
#                   but leave the two workers concurrent.
# REREAD            retention re-reads the index immediately before writing,
#                   instead of writing the snapshot it took at the start. No
#                   lock.
# LEASE             serialise both workers, but keep raw copyWith and the
#                   pre-await snapshot.
# PRODUCTION        what app_controller.dart does as of this writing: the
#                   generation guard (SegmentIndexCommit), the re-read
#                   (_commitSegmentMutation loads inside the critical section),
#                   and the mutex (_withSegmentIndex) together.
CONFIGURATIONS = ("unguarded", "generation_guard", "reread", "lease", "production")


class ModelViolation(RuntimeError):
    """Raised when an interleaving reaches an unsafe durable state."""


def fail(message: str) -> NoReturn:
    raise ModelViolation(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


@dataclass(frozen=True, slots=True)
class World:
    """One segment, two workers, and the durable state they contend over.

    `durable_*` is what `saveSegments` wrote and `loadSegments` reads back. The
    `*_snapshot_*` fields are each worker's private copy, taken at its read step
    and already stale by the time it writes -- which is the entire bug.
    """

    # Durable, on-disk index.
    durable_has_remote_key: bool = False
    durable_active_generation: int = 0
    durable_next_generation: int = 1
    # Physical audio file on disk.
    local_file_present: bool = True

    # Upload worker.
    u_phase: str = "idle"  # idle -> read -> returned -> done
    u_snapshot_has_remote_key: bool = False
    u_generation: int = 0

    # Retention worker.
    r_phase: str = "idle"  # idle -> read -> deleted -> done
    r_snapshot_has_remote_key: bool = False

    # Mutual exclusion, when the configuration provides it.
    lease_holder: str = "none"  # none | U | R

    # Ghost variable: did a verified remote acknowledgement ever become durable?
    # Never read by the implementation; it exists so the invariant can say
    # "this segment *was* backed up" after the evidence has been overwritten.
    ever_acknowledged: bool = False


# --------------------------------------------------------------------------
# Worker steps
# --------------------------------------------------------------------------


def _serialized(config: str) -> bool:
    """`AppController._withSegmentIndex` -- a promise-chained mutex."""
    return config in ("lease", "production")


def _generation_guarded(config: str) -> bool:
    """`SegmentIndexCommit.beginAttempt` / `.commitResult`."""
    return config in ("generation_guard", "production")


def _rereads(config: str) -> bool:
    """`_commitSegmentMutation` loads the index *inside* the critical section.

    The distinction this models is the one the doc comment on
    `SegmentIndexCommit` draws: "a commit is computed from the list that was
    just re-read, never from a list snapshotted before an `await`".
    """
    return config in ("reread", "production")


def u_read(world: World, config: str) -> World:
    """`_drainUploads`: loadSegments(), then mark the segment uploading.

    Under `generation_guard` this is `SegmentUploadStateMachine.begin`, which
    allocates a generation and publishes it durably. Under `unguarded` it is
    the raw `copyWith(uploadStatus: uploading)` the drain loop does today.
    """
    if _generation_guarded(config):
        generation = max(world.durable_next_generation, world.durable_active_generation + 1)
        return replace(
            world,
            u_phase="read",
            u_snapshot_has_remote_key=world.durable_has_remote_key,
            u_generation=generation,
            durable_active_generation=generation,
            durable_next_generation=generation + 1,
            lease_holder="U" if _serialized(config) else world.lease_holder,
        )
    return replace(
        world,
        u_phase="read",
        u_snapshot_has_remote_key=world.durable_has_remote_key,
        lease_holder="U" if _serialized(config) else world.lease_holder,
    )


def u_network_returns(world: World, config: str) -> World:
    """The S3/backend PUT completed. The bytes are in the cloud either way."""
    return replace(world, u_phase="returned")


def u_commit(world: World, config: str) -> World:
    """`_replaceSegment(updated)`: write the whole list back.

    Under `generation_guard` this is `succeed()`, which stutters unless the
    generation it began with still holds authority.
    """
    if _generation_guarded(config) and world.durable_active_generation != world.u_generation:
        # Late result: stutter, exactly as SegmentUploadStateMachine.succeed does.
        return replace(
            world,
            u_phase="done",
            lease_holder="none" if _serialized(config) else world.lease_holder,
        )
    return replace(
        world,
        u_phase="done",
        durable_has_remote_key=True,
        durable_active_generation=0,
        ever_acknowledged=True,
        lease_holder="none" if _serialized(config) else world.lease_holder,
    )


def r_read(world: World, config: str) -> World:
    """`_enforceRetention`: loadSegments() into a private list."""
    return replace(
        world,
        r_phase="read",
        r_snapshot_has_remote_key=world.durable_has_remote_key,
        lease_holder="R" if _serialized(config) else world.lease_holder,
    )


def r_delete_file(world: World, config: str) -> World:
    """Past the device-retention cutoff: the plaintext leaves the disk."""
    return replace(world, r_phase="deleted", local_file_present=False)


def r_reread(world: World, config: str) -> World:
    """Refresh the snapshot from the durable index just before writing.

    Modelled as a step of its own rather than folded into the write, because
    without the mutex there is still a gap between the two, and collapsing them
    would make this configuration look safe for a reason the code does not
    provide. Under the mutex nothing can interleave here anyway, so the extra
    step costs nothing and the unlocked case stays honest.
    """
    return replace(
        world,
        r_phase="reread",
        r_snapshot_has_remote_key=world.durable_has_remote_key,
    )


def r_commit(world: World, config: str) -> World:
    """`saveSegments(segments)`: write retention's snapshot back.

    This is the losing write when the snapshot is stale. Note what the
    generation guard does *not* do here: retention is not an upload transition,
    so `succeed`/`fail` never run on this path, and the whole-list write lands
    regardless of any generation.
    """
    return replace(
        world,
        r_phase="done",
        durable_has_remote_key=world.r_snapshot_has_remote_key,
        lease_holder="none" if _serialized(config) else world.lease_holder,
    )


U_STEPS = (("u_read", u_read), ("u_network_returns", u_network_returns), ("u_commit", u_commit))

_U_ORDER = {"idle": 0, "read": 1, "returned": 2, "done": 3}


def _r_steps(config: str):
    if _rereads(config):
        return (
            ("r_read", r_read),
            ("r_delete_file", r_delete_file),
            ("r_reread", r_reread),
            ("r_commit", r_commit),
        )
    return (("r_read", r_read), ("r_delete_file", r_delete_file), ("r_commit", r_commit))


def _r_order(config: str) -> dict[str, int]:
    if _rereads(config):
        return {"idle": 0, "read": 1, "deleted": 2, "reread": 3, "done": 4}
    return {"idle": 0, "read": 1, "deleted": 2, "done": 3}


def enabled(world: World, config: str) -> Iterator[tuple[str, World]]:
    """Whichever step each worker is up to, subject to the lease."""
    r_steps = _r_steps(config)
    u_index = _U_ORDER[world.u_phase]
    r_index = _r_order(config)[world.r_phase]

    if u_index < 3:
        label, step = U_STEPS[u_index]
        # The lease admits a worker only when nobody holds it, and holds it for
        # the worker's whole callback -- runWorker's barrier is established
        # synchronously before the first await.
        if not _serialized(config) or world.lease_holder in ("none", "U") or u_index > 0:
            if not (_serialized(config) and u_index == 0 and world.lease_holder != "none"):
                yield label, step(world, config)
    if r_index < len(r_steps):
        label, step = r_steps[r_index]
        if not (_serialized(config) and r_index == 0 and world.lease_holder != "none"):
            yield label, step(world, config)


# --------------------------------------------------------------------------
# Invariants
# --------------------------------------------------------------------------

INVARIANTS = (
    "no-unrecoverable-audio-loss",
    "acknowledgement-is-durable",
    "lease-is-exclusive",
)


def check(world: World, config: str) -> int:
    """Return the number of non-vacuous obligations checked on `world`."""
    tested = 0

    # no-unrecoverable-audio-loss. This is the CRITICAL one. The segment was
    # acknowledged in the cloud, the durable index no longer records where, and
    # the local copy is gone. Nothing on the device can now find that audio.
    if world.ever_acknowledged:
        tested += 1
        require(
            world.durable_has_remote_key or world.local_file_present,
            "unrecoverable audio loss: a verified remote key was overwritten "
            "while the local plaintext was already deleted",
        )

    # acknowledgement-is-durable: once written, a remote key may only be
    # cleared by cloud-retention expiry, which this model excludes.
    if world.ever_acknowledged and world.r_phase == "done" and world.u_phase == "done":
        tested += 1
        require(
            world.durable_has_remote_key,
            "a completed retention pass erased a completed upload's remote key",
        )

    # lease-is-exclusive: a serialized configuration must never have both
    # workers mid-callback at once.
    if _serialized(config):
        tested += 1
        require(
            not (
                world.u_phase in ("read", "returned")
                and world.r_phase in ("read", "deleted", "reread")
            ),
            "both workers are inside the retention lease simultaneously",
        )

    return tested


# --------------------------------------------------------------------------
# Exhaustive interleaving search
# --------------------------------------------------------------------------


@dataclass(slots=True)
class Outcome:
    config: str
    states: int
    transitions: int
    obligations: int
    counterexample: list[str] | None
    violation: str | None


def explore(config: str) -> Outcome:
    """Breadth-first over every interleaving; keep the shortest failing trace."""
    initial = World()
    seen = {initial}
    queue: list[tuple[World, list[str]]] = [(initial, [])]
    obligations = transitions = 0
    counterexample: list[str] | None = None
    violation: str | None = None

    while queue:
        world, trace = queue.pop(0)
        for label, nxt in enabled(world, config):
            transitions += 1
            if nxt in seen:
                continue
            seen.add(nxt)
            try:
                obligations += check(nxt, config)
            except ModelViolation as error:
                if counterexample is None:
                    counterexample = trace + [label]
                    violation = str(error)
                continue
            queue.append((nxt, trace + [label]))

    return Outcome(config, len(seen), transitions, obligations, counterexample, violation)


# The expectation for each configuration, so that a change in either direction
# is a failure rather than a silently different number.
EXPECTED = {
    "unguarded": "unsafe",
    # The finding worth the most attention. F1's stated fix is "route every
    # upload transition through begin/succeed/fail" -- and on its own that does
    # not close this race, because retention is not an upload transition. Its
    # whole-list `saveSegments` overwrites the acknowledged key no matter what
    # generation the upload held.
    "generation_guard": "unsafe",
    # The second finding. Re-reading before the write narrows the window a great
    # deal -- the upload must now land inside the gap between the re-read and
    # the write rather than anywhere in the whole retention pass -- but it does
    # not close it. A narrower race is still a race, and this one destroys
    # recorded audio when it lands.
    "reread": "unsafe",
    "lease": "safe",
    "production": "safe",
}


# ---------------------------------------------------------------------------
# Which row is this repository actually on?
# ---------------------------------------------------------------------------


def detect_production_configuration() -> dict[str, object]:
    """Read `app_controller.dart` and say which configuration it implements.

    Without this the table above is an interesting abstraction that nobody has
    to act on. With it, running the model in a repository answers the only
    question that matters: does the code in front of me admit the losing trace?

    Detection is syntactic and deliberately conservative -- it looks for the
    three named repairs and reports what it finds. A repository that fixes the
    race some other way will be reported as unguarded, which is the safe
    direction to be wrong in.
    """
    controller = Path(__file__).resolve().parents[1] / "lib/src/app/app_controller.dart"
    if not controller.exists():
        return {"detected": None, "note": f"no app_controller.dart at {controller}"}
    source = controller.read_text(encoding="utf-8")

    guarded = "SegmentIndexCommit." in source
    serialized = "_withSegmentIndex(" in source
    # The re-read is only meaningful inside the critical section; the marker is
    # the commit helper that loads the index itself rather than taking a list.
    rereads = "_commitSegmentMutation(" in source

    if serialized and guarded and rereads:
        detected = "production"
    elif serialized:
        detected = "lease"
    elif rereads:
        detected = "reread"
    elif guarded:
        detected = "generation_guard"
    else:
        detected = "unguarded"

    return {
        "detected": detected,
        "verdict": EXPECTED[detected],
        "generation_guard": guarded,
        "serialized": serialized,
        "rereads_inside_lock": rereads,
        "note": (
            "this repository admits the losing interleaving"
            if EXPECTED[detected] == "unsafe"
            else "this repository does not admit the losing interleaving"
        ),
    }


def verify() -> dict[str, object]:
    report: dict[str, object] = {}
    mismatches: list[str] = []
    for config in CONFIGURATIONS:
        outcome = explore(config)
        actual = "unsafe" if outcome.counterexample else "safe"
        if actual != EXPECTED[config]:
            mismatches.append(f"{config}: expected {EXPECTED[config]}, got {actual}")
        entry: dict[str, object] = {
            "verdict": actual,
            "expected": EXPECTED[config],
            "reachable_states": outcome.states,
            "transitions": outcome.transitions,
            "invariant_obligations_tested": outcome.obligations,
        }
        if outcome.counterexample:
            entry["counterexample"] = outcome.counterexample
            entry["violation"] = outcome.violation
        report[config] = entry

    require(
        not mismatches,
        "configuration verdicts drifted from the recorded expectation: "
        + "; ".join(mismatches),
    )
    detected = detect_production_configuration()
    return {
        "model": "sonus-concurrent-retention-v1",
        "claim": "exhaustive-two-worker-interleaving-over-one-segment",
        "status": "ok",
        "audit_finding": "AUDIT-2026-08-22 F1",
        "this_repository": detected,
        "invariants": list(INVARIANTS),
        "configurations": report,
        "conclusion": (
            "The shipped repair is sufficient, and neither half of it would "
            "have been on its own. The generation guard does not close the "
            "race because retention is not an upload transition, so its "
            "whole-list saveSegments overwrites an acknowledged remoteKey "
            "regardless of generation -- which means F1's own prescribed fix, "
            "taken literally, was not enough. Re-reading before the write only "
            "narrows the window. Serialising the two workers is what removes "
            "the counterexample, and app_controller.dart's _withSegmentIndex "
            "mutex plus SegmentIndexCommit's re-read-inside-the-lock is the "
            "'production' row: safe."
        ),
        "production_status": (
            "`this_repository` reports which row the checked-out "
            "app_controller.dart is on. sonus-auris-flutter.dart is on "
            "`production` (safe); sonus-auris-ui.dart was still on `unguarded` "
            "when this model was written."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", choices=CONFIGURATIONS,
                        help="print the shortest losing interleaving for one configuration")
    args = parser.parse_args()
    try:
        if args.trace:
            outcome = explore(args.trace)
            if outcome.counterexample is None:
                print(f"{args.trace}: no counterexample -- configuration is safe")
                return 0
            print(f"{args.trace}: {outcome.violation}\n")
            for step, label in enumerate(outcome.counterexample, start=1):
                print(f"  {step}. {label}")
            return 0
        print(json.dumps(verify(), sort_keys=True))
    except ModelViolation as violation:
        print(f"MODEL VIOLATION: {violation}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
