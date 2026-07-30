#!/usr/bin/env python3
"""Finite crash-interleaving model for Sonus Auris local-retention tombstones."""

from __future__ import annotations

import argparse
import json
import sys
import tomllib
from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

ACTIONS = ("tombstone", "delete", "persist_index", "clear_journal", "recover", "crash")


@dataclass(frozen=True, slots=True)
class State:
    backed_up: bool
    journal: bool = False
    artifacts_present: bool = True
    index_local: bool = True
    expiry_failure: bool = False


def transition(state: State, action: str) -> State:
    if action == "crash":
        return state
    if action == "tombstone":
        if state.index_local and state.artifacts_present:
            return State(state.backed_up, True, True, True, state.expiry_failure)
        return state
    if action == "delete" and state.journal:
        return State(state.backed_up, True, False, state.index_local, state.expiry_failure)
    if action == "persist_index" and state.journal and not state.artifacts_present:
        return State(state.backed_up, True, False, False, state.expiry_failure or not state.backed_up)
    if action == "clear_journal" and state.journal and not state.artifacts_present and not state.index_local:
        return State(state.backed_up, False, False, False, state.expiry_failure)
    if action == "recover":
        if not state.journal:
            return state
        return State(state.backed_up, False, False, False, state.expiry_failure or not state.backed_up)
    if action in ACTIONS:
        return state
    raise ValueError(f"unsupported action: {action}")


def assert_invariants(state: State) -> int:
    if not state.artifacts_present and state.index_local:
        assert state.journal, "deletion can race metadata only behind a durable tombstone"
    if not state.journal and not state.artifacts_present:
        assert not state.index_local, "cleared journal cannot leave a stale local path"
    if state.expiry_failure:
        assert not state.backed_up and not state.index_local
    if not state.backed_up and not state.index_local:
        assert state.expiry_failure, "unbacked expiry must remain visible"
    return 5


def load_manifest() -> dict[str, Any]:
    with Path(__file__).with_name("fm.toml").open("rb") as handle:
        profile = tomllib.load(handle)["procedures"]["retention_journal"]
    assert profile["schema_version"] == 1
    assert profile["adapter_protocol"] == "json-stdin/v1"
    assert profile["model"] == "formal/retention_journal_model.py"
    assert set(profile["invariants"]) == {
        "journal-before-delete", "no-journal-no-stale-local-index",
        "unbacked-expiry-visible", "recovery-converges", "terminal-idempotence",
    }
    return profile


def reachable(backed_up: bool, depth: int) -> tuple[set[State], int, int]:
    initial = State(backed_up=backed_up)
    seen = {initial}
    queue = deque([(initial, 0)])
    checks = transitions = 0
    while queue:
        state, level = queue.popleft()
        checks += assert_invariants(state)
        if level >= depth:
            continue
        for action in ACTIONS:
            next_state = transition(state, action)
            transitions += 1
            checks += assert_invariants(next_state)
            if next_state not in seen:
                seen.add(next_state)
                queue.append((next_state, level + 1))
    return seen, checks, transitions


def verify() -> dict[str, Any]:
    profile = load_manifest()
    total_checks = total_transitions = total_states = 0
    for backed_up in (False, True):
        states, checks, transitions = reachable(backed_up, int(profile["transition_depth"]))
        total_checks += checks
        total_transitions += transitions
        total_states += len(states)
        for state in states:
            if state.journal:
                recovered = transition(state, "recover")
                assert recovered == transition(recovered, "recover")
                assert not recovered.journal and not recovered.artifacts_present and not recovered.index_local
                assert recovered.expiry_failure == (not backed_up)
                total_checks += 5
        state = State(backed_up=backed_up)
        for action in ("tombstone", "delete", "persist_index", "clear_journal"):
            state = transition(state, action)
        assert not state.journal and not state.artifacts_present and not state.index_local
        assert state.expiry_failure == (not backed_up)
        assert state == transition(state, "recover") == transition(state, "clear_journal")
        total_checks += 4
    return {"status": "ok", "model": profile["id"], "claim": profile["claim"], "reachable_states": total_states, "transitions": total_transitions, "checks": total_checks}


def replay_request(request: dict[str, Any]) -> dict[str, Any]:
    if request.get("op") != "replay":
        raise ValueError("supported op is replay")
    state = State(backed_up=bool(request.get("backed_up", False)))
    trace = [asdict(state)]
    for action in request.get("events", []):
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
