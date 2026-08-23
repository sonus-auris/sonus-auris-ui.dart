#!/usr/bin/env python3
"""Finite crash-interleaving model for Sonus Auris local-retention tombstones.

The point of this model is the `crash` action. A retention mutation is not one
atomic act: the app writes a durable tombstone, deletes the audio from disk,
updates its in-memory segment list, then persists the index. A crash can land
between any two of those, and what a crash destroys is the volatile half --
the in-memory view -- while leaving the durable half exactly as it was.

`State` therefore carries both halves of the index:

    index_local   the persisted index on disk, what `loadSegments` reads back
    index_memory  the in-memory `SegmentIndex` the running process holds

and `crash` discards the volatile half by reloading it from the durable one.
That is the whole abstraction. A `crash` that returned the state unchanged --
which is what this model used to do -- made the crash-after-delete trace
identical to the same trace with `crash` removed, so the CI step named "crash
recovery" was checking a no-op.

Every check raises explicitly rather than using `assert`, so that running this
under `python3 -O` cannot silently disable the model.
"""

from __future__ import annotations

import argparse
import json
import sys
import tomllib
from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, NoReturn

ACTIONS = ("tombstone", "delete", "persist_index", "clear_journal", "recover", "crash")


class ModelViolation(RuntimeError):
    """Raised when a reachable state or a manifest violates the model contract."""


def fail(message: str) -> NoReturn:
    raise ModelViolation(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


@dataclass(frozen=True, slots=True)
class State:
    backed_up: bool
    journal: bool = False
    artifacts_present: bool = True
    # Durable: survives a crash. This is what loadSegments() reads at startup.
    index_local: bool = True
    # Volatile: the in-memory SegmentIndex the running process holds. A crash
    # loses it, and the process comes back with whatever is on disk.
    index_memory: bool = True
    expiry_failure: bool = False


def transition(state: State, action: str) -> State:
    if action == "crash":
        # Discard the volatile half of the state and reload it from the durable
        # half, exactly as a restart does. fm.toml records this as
        # crash_model = "restart clears volatile upload state and preserves
        # persisted index/tombstone state".
        return State(
            state.backed_up,
            state.journal,
            state.artifacts_present,
            state.index_local,
            state.index_local,
            state.expiry_failure,
        )
    if action == "tombstone":
        if state.index_local and state.index_memory and state.artifacts_present:
            return State(state.backed_up, True, True, True, True, state.expiry_failure)
        return state
    if action == "delete" and state.journal and state.artifacts_present:
        # The audio is gone from disk and the running process has dropped it
        # from its in-memory list. The persisted index still names it; only the
        # durable tombstone explains the gap.
        return State(state.backed_up, True, False, state.index_local, False, state.expiry_failure)
    if (
        action == "persist_index"
        and state.journal
        and not state.artifacts_present
        and not state.index_memory
    ):
        # Flush the in-memory view to disk.
        return State(
            state.backed_up, True, False, False, False, state.expiry_failure or not state.backed_up
        )
    if (
        action == "clear_journal"
        and state.journal
        and not state.artifacts_present
        and not state.index_local
        and not state.index_memory
    ):
        return State(state.backed_up, False, False, False, False, state.expiry_failure)
    if action == "recover":
        # Journal replay at startup: finish the whole mutation in one durable
        # step, whatever stage the crash interrupted.
        if not state.journal:
            return state
        return State(
            state.backed_up, False, False, False, False, state.expiry_failure or not state.backed_up
        )
    if action in ACTIONS:
        return state
    fail(f"unsupported action: {action}")


def assert_invariants(state: State) -> int:
    """Check every invariant on `state`; return how many were non-vacuous.

    The return value counts only obligations whose antecedent actually held, so
    the consequent was genuinely tested on this state. It varies from state to
    state, and summing it gives the number of real checks performed rather than
    a constant multiplied by the number of states visited.
    """
    tested = 0

    # journal-before-delete: nothing may name a segment whose bytes are gone
    # unless a durable tombstone explains it. Covers both halves of the index,
    # which is what makes the crash-interleaved states meaningful.
    if not state.artifacts_present and (state.index_local or state.index_memory):
        tested += 1
        require(state.journal, "deletion can race metadata only behind a durable tombstone")

    # no-journal-no-stale-local-index: once the journal is cleared, neither the
    # persisted index nor the in-memory view may still point at the segment.
    if not state.journal and not state.artifacts_present:
        tested += 1
        require(
            not state.index_local and not state.index_memory,
            "cleared journal cannot leave a stale local path on disk or in memory",
        )

    # unbacked-expiry-visible, both directions.
    if state.expiry_failure:
        tested += 1
        require(
            not state.backed_up and not state.index_local and not state.index_memory,
            "a recorded expiry failure describes an unbacked, fully de-indexed segment",
        )
    if not state.backed_up and not state.index_local:
        tested += 1
        require(state.expiry_failure, "unbacked expiry must remain visible")

    # A crash reloads the in-memory view from disk, so any state the process
    # can be in after a restart has the two halves in agreement. This is the
    # obligation that the old no-op `crash` could not state at all.
    if not state.journal:
        tested += 1
        require(
            state.index_local == state.index_memory,
            "outside a journalled mutation the in-memory view must match the persisted index",
        )

    return tested


def load_manifest() -> dict[str, Any]:
    with Path(__file__).with_name("fm.toml").open("rb") as handle:
        profile = tomllib.load(handle)["procedures"]["retention_journal"]
    require(profile["schema_version"] == 1, "unsupported procedure schema_version")
    require(profile["adapter_protocol"] == "json-stdin/v1", "unsupported adapter protocol")
    require(
        profile["model"] == "formal/retention_journal_model.py",
        "the manifest names a different model file",
    )
    expected = {
        "journal-before-delete",
        "no-journal-no-stale-local-index",
        "unbacked-expiry-visible",
        "recovery-converges",
        "terminal-idempotence",
    }
    require(
        set(profile["invariants"]) == expected,
        f"manifest invariants drifted: {sorted(set(profile['invariants']) ^ expected)}",
    )
    return profile


def reachable(backed_up: bool, depth: int) -> tuple[set[State], int, int]:
    initial = State(backed_up=backed_up)
    seen = {initial}
    queue = deque([(initial, 0)])
    tested = transitions = 0
    while queue:
        state, level = queue.popleft()
        tested += assert_invariants(state)
        if level >= depth:
            continue
        for action in ACTIONS:
            next_state = transition(state, action)
            transitions += 1
            tested += assert_invariants(next_state)
            if next_state not in seen:
                seen.add(next_state)
                queue.append((next_state, level + 1))
    return seen, tested, transitions


def _crash_is_not_a_stutter() -> int:
    """`crash` must actually discard something, or this model claims nothing.

    The CI witness trace is ["tombstone", "delete", "crash", "recover"]. If
    `crash` were the identity, dropping it from that list would produce the
    same trace and the "crash recovery" check would be checking nothing. This
    asserts the opposite, and is the guard against that regression returning.
    """
    tested = 0
    for backed_up in (False, True):
        with_crash = State(backed_up=backed_up)
        without_crash = State(backed_up=backed_up)
        for action in ("tombstone", "delete", "crash"):
            with_crash = transition(with_crash, action)
        for action in ("tombstone", "delete"):
            without_crash = transition(without_crash, action)
        require(
            with_crash != without_crash,
            "crash is a stutter step: the crash-interleaving abstraction is vacuous",
        )
        require(
            with_crash.index_memory and not without_crash.index_memory,
            "crash must restore the in-memory view from the persisted index",
        )
        require(
            with_crash.artifacts_present is False and with_crash.journal,
            "crash must preserve the durable tombstone and the on-disk deletion",
        )
        tested += 3
    return tested


def verify() -> dict[str, Any]:
    profile = load_manifest()
    tested = _crash_is_not_a_stutter()
    total_transitions = total_states = 0
    for backed_up in (False, True):
        states, state_tested, transitions = reachable(backed_up, int(profile["transition_depth"]))
        tested += state_tested
        total_transitions += transitions
        total_states += len(states)

        # recovery-converges: from ANY reachable journalled state -- including
        # every crash-interleaved one -- one replay reaches the same converged
        # state, and a second replay changes nothing.
        for state in states:
            if state.journal:
                recovered = transition(state, "recover")
                require(recovered == transition(recovered, "recover"), "recovery is not idempotent")
                require(
                    not recovered.journal
                    and not recovered.artifacts_present
                    and not recovered.index_local
                    and not recovered.index_memory,
                    "recovery did not converge to a fully de-indexed segment",
                )
                require(
                    recovered.expiry_failure == (not backed_up),
                    "recovery lost the unbacked-expiry record",
                )
                tested += 3

        # terminal-idempotence: the happy path ends somewhere no further action
        # can move, and a crash there changes nothing either.
        state = State(backed_up=backed_up)
        for action in ("tombstone", "delete", "persist_index", "clear_journal"):
            state = transition(state, action)
        require(
            not state.journal
            and not state.artifacts_present
            and not state.index_local
            and not state.index_memory,
            "the happy path did not reach the converged terminal state",
        )
        require(state.expiry_failure == (not backed_up), "terminal state lost the expiry record")
        for action in ACTIONS:
            require(transition(state, action) == state, f"terminal state moved under {action}")
        tested += 2 + len(ACTIONS)

    return {
        "status": "ok",
        "model": profile["id"],
        "claim": profile["claim"],
        "reachable_states": total_states,
        "transitions": total_transitions,
        # Non-vacuous obligations only: every count here is a consequent that
        # was actually evaluated, not a constant times a state count.
        "invariant_obligations_tested": tested,
    }


def replay_request(request: dict[str, Any]) -> dict[str, Any]:
    if request.get("op") != "replay":
        fail("supported op is replay")
    state = State(backed_up=bool(request.get("backed_up", False)))
    trace = [asdict(state)]
    events = request.get("events", [])
    if not isinstance(events, list):
        fail("events must be a list of action names")
    for action in events:
        state = transition(state, str(action))
        assert_invariants(state)
        trace.append(asdict(state))
    return {"final": asdict(state), "trace": trace}


def emit(records: Iterable[dict[str, Any]]) -> None:
    for record in records:
        print(json.dumps(record, sort_keys=True, separators=(",", ":")))


def replay() -> None:
    load_manifest()
    outputs = []
    for line_number, raw in enumerate(sys.stdin, start=1):
        raw = raw.strip()
        if raw:
            outputs.append({"schema_version": 1, "line": line_number, **replay_request(json.loads(raw))})
    emit(outputs)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json-stdin", action="store_true")
    args = parser.parse_args()
    if args.json_stdin:
        replay()
    else:
        print(json.dumps(verify(), sort_keys=True))


if __name__ == "__main__":
    main()
