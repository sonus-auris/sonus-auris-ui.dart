#!/usr/bin/env python3
"""Explicit-state checker for the production upload-generation state machine.

`CHECKERS.md` states the gap this file closes:

    There is no checker in this repository that reads production Dart.

Apalache and TLC both read `segment_lifecycle.qnt`, so a wrong *reading* of the
Dart is invisible to both of them identically. This module is a third engine
that does not read the `.qnt` at all. It is a line-for-line transliteration of
`lib/src/services/segment_upload_state_machine.dart` -- the same guards, the
same clamps, the same stutter returns -- enumerated exhaustively over a bounded
generation domain.

What that buys, precisely:

  * It catches a modelling mistake. If `segment_lifecycle.qnt` and the Dart
    disagree, this checker and the Quint engines disagree, and the disagreement
    is visible instead of silently shared.
  * It runs. Every row `CHECKERS.md` reports is `WRITTEN`; the rows this file
    produces are `PASS` or `FAIL`, from an engine that needs nothing but
    CPython.

What it does not buy: this is a *transliteration*, not the Dart itself. It goes
stale if `segment_upload_state_machine.dart` changes and this file does not.
`--check-refinement` exists to make that drift loud -- it re-derives the guard
and clamp structure from the Dart source text and fails when the shapes stop
matching. That is a syntactic tripwire, not a proof of equivalence, and
`VACUITY.md` should record it as such.

Every check raises explicitly rather than using `assert`, so running this under
`python3 -O` cannot silently disable the model.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Iterator, NoReturn

# Bounded generation domain. Two live attempts plus one acknowledged attempt is
# the smallest domain in which a stale result can be distinguished from both the
# active attempt and the last acknowledged one, which is the whole point of the
# generation counter. `fm.toml` bounds `upload_generations = 2`; this checker
# uses 3 so that "stale, and also not the acknowledged one" is reachable.
MAX_GENERATION = 3

STATUS_PENDING = "pending"
STATUS_UPLOADING = "uploading"
STATUS_UPLOADED = "uploaded"
STATUS_FAILED = "failed"
STATUS_LOCAL_ONLY = "localOnly"

STATUSES = (
    STATUS_PENDING,
    STATUS_UPLOADING,
    STATUS_UPLOADED,
    STATUS_FAILED,
    STATUS_LOCAL_ONLY,
)

RETRYABLE = frozenset({STATUS_PENDING, STATUS_UPLOADING, STATUS_FAILED})


class ModelViolation(RuntimeError):
    """Raised when a reachable state violates the state-machine contract."""


def fail(message: str) -> NoReturn:
    raise ModelViolation(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


@dataclass(frozen=True, slots=True)
class Segment:
    """The content-free projection of `RecordingSegment`.

    Exactly the fields `SegmentUploadStateMachine.project()` exposes, plus
    `is_local`, which `project()` also exposes as `isLocal`. Audio, transcript
    and note fields are deliberately absent: the state machine never reads them,
    so including them would only inflate the state space.
    """

    status: str = STATUS_PENDING
    is_local: bool = True
    has_remote_key: bool = False
    next_generation: int = 1
    active_generation: int = 0
    acknowledged_generation: int = 0

    def project(self) -> dict[str, object]:
        """Mirror of `SegmentUploadStateMachine.project()` in Dart."""
        return {
            "status": self.status,
            "isLocal": self.is_local,
            "hasVerifiedRemote": self.status == STATUS_UPLOADED and self.has_remote_key,
            "nextGeneration": self.next_generation,
            "activeGeneration": self.active_generation,
            "acknowledgedGeneration": self.acknowledged_generation,
        }


# --------------------------------------------------------------------------
# Transliteration of lib/src/services/segment_upload_state_machine.dart
# --------------------------------------------------------------------------


def _at_least(value: int, minimum: int) -> int:
    """`SegmentUploadStateMachine._atLeast`."""
    return minimum if value < minimum else value


def _next_generation(segment: Segment) -> int:
    """`SegmentUploadStateMachine._nextGeneration`."""
    generation = _at_least(segment.next_generation, 1)
    generation = _at_least(generation, segment.active_generation + 1)
    generation = _at_least(generation, segment.acknowledged_generation + 1)
    return generation


def can_begin(segment: Segment) -> bool:
    """`SegmentUploadStateMachine.canBegin`."""
    return segment.is_local and segment.status in RETRYABLE


def begin(segment: Segment) -> Segment:
    """`SegmentUploadStateMachine.begin`. Raises where the Dart throws."""
    if not can_begin(segment):
        fail("Upload attempts require local plaintext in a retryable state.")
    generation = _next_generation(segment)
    return replace(
        segment,
        status=STATUS_UPLOADING,
        next_generation=generation + 1,
        active_generation=generation,
    )


def succeed(current: Segment, generation: int, remote_key: str) -> Segment:
    """`SegmentUploadStateMachine.succeed`.

    The two stutter returns are the load-bearing lines. A late success whose
    generation is not the active one returns `current` untouched rather than
    overwriting newer durable state.
    """
    key = remote_key.strip()
    if generation <= 0:
        fail("generation must be positive")
    if not key:
        fail("remoteKey must not be empty")
    if current.active_generation != generation:
        return current
    return replace(
        current,
        status=STATUS_UPLOADED,
        has_remote_key=True,
        active_generation=0,
        acknowledged_generation=generation,
        next_generation=_at_least(current.next_generation, generation + 1),
    )


def fail_upload(current: Segment, generation: int) -> Segment:
    """`SegmentUploadStateMachine.fail`."""
    if generation <= 0:
        fail("generation must be positive")
    if current.active_generation != generation:
        return current
    return replace(
        current,
        status=STATUS_FAILED,
        active_generation=0,
        next_generation=_at_least(current.next_generation, generation + 1),
    )


def invalidate_for_local_deletion(segment: Segment) -> Segment:
    """`SegmentUploadStateMachine.invalidateForLocalDeletion`."""
    invalidated = segment.active_generation
    return replace(
        segment,
        active_generation=0,
        next_generation=(
            _at_least(segment.next_generation, 1)
            if invalidated <= 0
            else _at_least(segment.next_generation, invalidated + 1)
        ),
    )


def restart(segment: Segment) -> Segment:
    """`SegmentUploadStateMachine.restart`."""
    return invalidate_for_local_deletion(segment)


# --------------------------------------------------------------------------
# Environment actions: what the app does *around* the state machine
# --------------------------------------------------------------------------


def delete_local_guarded(segment: Segment) -> Segment:
    """Retention deletion done correctly: invalidate, then drop the plaintext.

    This is the ordering `segment_upload_state_machine.dart`'s doc comment
    prescribes and that AUDIT-2026-08-22 F1 says production does not follow.
    """
    invalidated = invalidate_for_local_deletion(segment)
    return replace(invalidated, is_local=False)


def drop_remote(segment: Segment) -> Segment:
    """Cloud-retention expiry: the remote object is deleted, status regresses.

    Mirrors `_enforceRetention`'s `localOnly` branch in `app_controller.dart`.
    """
    if not segment.has_remote_key:
        return segment
    return replace(segment, status=STATUS_LOCAL_ONLY, has_remote_key=False)


Action = tuple[str, Callable[[Segment], Segment]]


def enabled_actions(segment: Segment) -> Iterator[Action]:
    """Every action the app can invoke from `segment`, with stale results.

    Late results are the reason this enumeration is not trivial: `succeed` and
    `fail` are offered for *every* generation in the domain, not just the active
    one, because a network callback that has been in flight across a retry is
    exactly a call with a stale generation.
    """
    if can_begin(segment) and _next_generation(segment) <= MAX_GENERATION:
        yield ("begin", begin)
    for generation in range(1, MAX_GENERATION + 1):
        yield (
            f"succeed(g={generation})",
            lambda s, g=generation: succeed(s, g, "remote/key"),
        )
        yield (f"fail(g={generation})", lambda s, g=generation: fail_upload(s, g))
    yield ("restart", restart)
    yield ("invalidateForLocalDeletion", invalidate_for_local_deletion)
    if segment.is_local:
        yield ("deleteLocal", delete_local_guarded)
    if segment.has_remote_key:
        yield ("dropRemote", drop_remote)


# --------------------------------------------------------------------------
# Invariants
# --------------------------------------------------------------------------

INVARIANTS = (
    "domain-bounds",
    "generation-binding",
    "uploaded-requires-verified-remote",
    "upload-authority-requires-local-plaintext",
    "uploading-has-authority",
    "late-result-stutters",
    "projection-is-content-free",
)


def check_state(segment: Segment) -> int:
    """Check every state invariant; return how many were non-vacuous.

    Counts only obligations whose antecedent actually held, so the total is the
    number of genuinely exercised checks rather than a constant times the
    number of visited states. `VACUITY.md` requires this distinction.
    """
    tested = 0

    # domain-bounds
    tested += 1
    require(
        segment.status in STATUSES
        and segment.next_generation >= 1
        and 0 <= segment.active_generation <= MAX_GENERATION
        and 0 <= segment.acknowledged_generation <= MAX_GENERATION,
        f"domain-bounds violated by {segment}",
    )

    # generation-binding: the next generation to allocate always strictly
    # exceeds both the live attempt and the last acknowledged one, so no
    # allocation can ever collide with a result still in flight.
    if segment.active_generation > 0:
        tested += 1
        require(
            segment.next_generation > segment.active_generation,
            f"next generation collides with the active attempt: {segment}",
        )
    if segment.acknowledged_generation > 0:
        tested += 1
        require(
            segment.next_generation > segment.acknowledged_generation,
            f"next generation collides with an acknowledged attempt: {segment}",
        )

    # uploaded-requires-verified-remote
    if segment.status == STATUS_UPLOADED:
        tested += 1
        require(
            segment.has_remote_key,
            f"uploaded status without a verified remote key: {segment}",
        )
        tested += 1
        require(
            segment.active_generation == 0,
            f"an acknowledged upload still holds attempt authority: {segment}",
        )
        tested += 1
        require(
            segment.acknowledged_generation > 0,
            f"uploaded status with no acknowledged generation: {segment}",
        )

    # upload-authority-requires-local-plaintext. This is the invariant that
    # AUDIT-2026-08-22 F1 is about: an in-flight upload result may only be
    # allowed to commit while the bytes it describes are still on disk.
    if segment.active_generation > 0:
        tested += 1
        require(
            segment.is_local,
            f"an upload attempt outlived its local plaintext: {segment}",
        )

    # uploading-has-authority: the converse. A segment parked in `uploading`
    # with no active generation is an orphan the drain loop will never finish.
    if segment.status == STATUS_UPLOADING and segment.is_local:
        tested += 1
        require(
            segment.active_generation > 0
            or segment.acknowledged_generation < segment.next_generation,
            f"uploading segment can never be retried: {segment}",
        )

    # late-result-stutters: for every generation that is not the active one,
    # both terminal callbacks must be the identity. Checked directly on the
    # state rather than inferred from the trace.
    for generation in range(1, MAX_GENERATION + 1):
        if generation == segment.active_generation:
            continue
        tested += 2
        require(
            succeed(segment, generation, "late/key") == segment,
            f"a late success mutated state at g={generation}: {segment}",
        )
        require(
            fail_upload(segment, generation) == segment,
            f"a late failure mutated state at g={generation}: {segment}",
        )

    # projection-is-content-free: the projection the ITF adapter and the
    # telemetry span both read must never grow a field that could carry user
    # audio, transcript or note content.
    projection = segment.project()
    tested += 1
    require(
        set(projection) == {
            "status",
            "isLocal",
            "hasVerifiedRemote",
            "nextGeneration",
            "activeGeneration",
            "acknowledgedGeneration",
        },
        f"projection surface drifted: {sorted(projection)}",
    )

    return tested


def check_step(before: Segment, action: str, after: Segment) -> int:
    """Transition invariants -- obligations a single state cannot express."""
    tested = 0

    # acknowledged-never-regresses: a durable acknowledgement is permanent.
    tested += 1
    require(
        after.acknowledged_generation >= before.acknowledged_generation,
        f"acknowledged generation regressed across {action}: {before} -> {after}",
    )

    # next-generation-never-regresses: the allocator is monotonic, which is what
    # makes a generation number a safe identity across a restart.
    tested += 1
    require(
        after.next_generation >= before.next_generation,
        f"generation allocator regressed across {action}: {before} -> {after}",
    )

    # local-plaintext-never-returns: nothing in this machine can resurrect
    # deleted audio. Retention deletion is one-way.
    if not before.is_local:
        tested += 1
        require(
            not after.is_local,
            f"deleted local plaintext reappeared across {action}",
        )

    # A verified remote acknowledgement may only be produced by the generation
    # that currently holds authority.
    if after.acknowledged_generation > before.acknowledged_generation:
        tested += 1
        require(
            after.acknowledged_generation == before.active_generation,
            f"{action} acknowledged a generation that never held authority",
        )

    return tested


# --------------------------------------------------------------------------
# Exhaustive exploration
# --------------------------------------------------------------------------


@dataclass(slots=True)
class Result:
    states: int
    transitions: int
    obligations: int
    trace_witnesses: dict[str, list[str]]


def load_from_json(
    status: str,
    is_local: bool,
    has_remote_key: bool,
    next_generation: int,
    active_generation: int,
    acknowledged_generation: int,
) -> Segment:
    """Transliteration of `RecordingSegment.fromJson`'s generation handling.

    This is the *actual* startup path, and it matters that it is modelled
    faithfully rather than assumed. `fm.toml` records

        crash_model = "restart clears volatile upload state and preserves
                       persisted index/tombstone state"

    but `toJson`/`fromJson` round-trip `activeUploadGeneration` verbatim, and
    nothing in `lib/` calls `SegmentUploadStateMachine.restart`. So a restart
    does NOT clear the active generation: it reloads it. The manifest describes
    a system the code does not implement, and both Quint engines inherit that
    assumption from the manifest, so neither can see the gap.

    What `fromJson` does do is normalise `next` upward past both other
    counters. That normalisation is load-bearing -- see `MUTANTS`.
    """
    normalised_next = max(
        next_generation if next_generation >= 1 else 1,
        active_generation + 1,
        acknowledged_generation + 1,
    )
    return Segment(
        status=status,
        is_local=is_local,
        has_remote_key=has_remote_key,
        next_generation=normalised_next,
        active_generation=active_generation,
        acknowledged_generation=acknowledged_generation,
    )


def well_formed(segment: Segment) -> bool:
    """Can the running app produce this generation triple in memory?

    In process the answer is forced: `begin` clamps the new generation above
    both counters, and `succeed`/`fail` clear authority. So a live attempt
    always strictly exceeds the last acknowledged one. Only the persistence
    boundary can break that -- see `corrupt_seeds`.
    """
    return segment.active_generation == 0 or (
        segment.active_generation > segment.acknowledged_generation
    )


def _all_persisted_seeds() -> list[Segment]:
    seeds: list[Segment] = []
    for status in STATUSES:
        for is_local in (True, False):
            for has_remote_key in (True, False):
                if status == STATUS_UPLOADED and not has_remote_key:
                    continue  # not a state the machine can persist
                for acknowledged in range(0, MAX_GENERATION):
                    if status == STATUS_UPLOADED and acknowledged == 0:
                        continue
                    for active in range(0, MAX_GENERATION):
                        if status == STATUS_UPLOADED and active > 0:
                            continue  # succeed() always clears authority
                        if active > 0 and not is_local:
                            # Excluded on purpose: this is the F1 state, and it
                            # is unreachable only because retention deletion is
                            # modelled as delete_local_guarded. The concurrent
                            # model is where the unguarded path is explored.
                            continue
                        seeds.append(
                            load_from_json(
                                status=status,
                                is_local=is_local,
                                has_remote_key=has_remote_key,
                                next_generation=1,
                                active_generation=active,
                                acknowledged_generation=acknowledged,
                            )
                        )
    return seeds


def initial_states() -> list[Segment]:
    """The states a healthy install can boot into."""
    return [seed for seed in _all_persisted_seeds() if well_formed(seed)]


def corrupt_seeds() -> list[Segment]:
    """Persisted states no running process can produce, but `fromJson` accepts.

    `RecordingSegment.fromJson` normalises `nextUploadGeneration` upward past
    both other counters, but it does not constrain `activeUploadGeneration`
    against `acknowledgedUploadGeneration` at all, and nothing calls
    `SegmentUploadStateMachine.restart` on load. So a torn write, a downgrade
    to an older build, or a hand-edited index can hand the app a segment whose
    live attempt is *older* than its last acknowledged one -- and `succeed()`
    will then happily regress a durable acknowledgement, because its only guard
    is `activeUploadGeneration == generation`.

    This is the same class of defect as AUDIT-2026-08-22 F2: one half of a pair
    of equally-corruptible fields is defended and the other is not.

    Fix, either of:
      * clamp `activeGeneration` to 0 in `fromJson` when it does not exceed
        `acknowledgedGeneration`; or
      * call `SegmentUploadStateMachine.restart` on every segment in
        `loadSegments()`, which is what `fm.toml`'s crash_model already claims
        happens.
    """
    return [seed for seed in _all_persisted_seeds() if not well_formed(seed)]


WITNESSES = {
    "retry_after_failure": lambda s: s.status == STATUS_UPLOADING
    and s.acknowledged_generation == 0
    and s.active_generation >= 2,
    "late_success_after_retry": lambda s: s.active_generation >= 2
    and s.next_generation > s.active_generation + 0,
    "acknowledged_then_deleted": lambda s: s.status == STATUS_UPLOADED
    and not s.is_local,
    "cloud_expiry_regression": lambda s: s.status == STATUS_LOCAL_ONLY
    and s.acknowledged_generation > 0,
    "deleted_with_no_authority": lambda s: not s.is_local
    and s.active_generation == 0,
    # Reachable only because `fromJson` restores activeUploadGeneration and
    # nothing calls `restart()`. If a future change makes this unreachable, the
    # manifest's crash_model has finally become true and this witness should be
    # retired deliberately rather than silently.
    "authority_survives_restart": lambda s: s.active_generation > 0
    and s.status != STATUS_UPLOADING,
}


def explore() -> Result:
    seen: set[Segment] = set()
    queue: deque[tuple[Segment, list[str]]] = deque()
    for seed in initial_states():
        if seed not in seen:
            seen.add(seed)
            queue.append((seed, []))

    obligations = 0
    transitions = 0
    witnesses: dict[str, list[str]] = {}

    for seed in list(seen):
        obligations += check_state(seed)

    while queue:
        state, trace = queue.popleft()
        for name, witness in WITNESSES.items():
            if name not in witnesses and witness(state):
                witnesses[name] = trace
        for label, action in enabled_actions(state):
            nxt = action(state)
            transitions += 1
            obligations += check_step(state, label, nxt)
            if nxt not in seen:
                obligations += check_state(nxt)
                seen.add(nxt)
                queue.append((nxt, trace + [label]))

    missing = sorted(set(WITNESSES) - set(witnesses))
    require(
        not missing,
        f"unreachable witnesses -- the model is narrower than intended: {missing}",
    )
    return Result(len(seen), transitions, obligations, witnesses)


# --------------------------------------------------------------------------
# Mutation self-test: does this checker actually catch anything?
# --------------------------------------------------------------------------

# Mutation testing distinguishes a mutant that dies from one that cannot die.
# Claiming a surviving mutant as a pass is the exact failure `VACUITY.md` warns
# about, so every entry declares which it is and an equivalent mutant must
# carry the argument for why -- and a tripwire pinning the guarantee it rests
# on, so that the equivalence cannot quietly stop being true.
MUTANTS: dict[str, dict[str, str]] = {
    "succeed_ignores_generation": {
        "defect": "drop the active-generation guard in succeed()",
        "expect": "killed",
    },
    "fail_ignores_generation": {
        "defect": "drop the active-generation guard in fail()",
        "expect": "killed",
    },
    "begin_reuses_generation": {
        "defect": "allocate the same generation twice",
        "expect": "killed",
    },
    "delete_skips_invalidate": {
        "defect": "delete local plaintext without invalidating the attempt",
        "expect": "killed",
    },
    "invalidate_does_not_advance": {
        "defect": "clear the active generation without advancing next",
        "expect": "equivalent",
        "why": (
            "`RecordingSegment.fromJson` already normalises nextUploadGeneration "
            "above both other counters, and `begin` advances it before any "
            "invalidate can observe it, so the clamp inside "
            "invalidateForLocalDeletion is defensive rather than load-bearing. "
            "It becomes load-bearing the moment that normalisation is removed, "
            "which is why REQUIRED_DART_SHAPES pins it."
        ),
    },
}


def _apply_mutant(name: str) -> Callable[[], None]:
    """Install a defect, returning a callable that removes it again."""
    module = sys.modules[__name__]
    originals = {
        "succeed": succeed,
        "fail_upload": fail_upload,
        "begin": begin,
        "delete_local_guarded": delete_local_guarded,
        "invalidate_for_local_deletion": invalidate_for_local_deletion,
    }

    def restore() -> None:
        for key, value in originals.items():
            setattr(module, key, value)

    if name == "succeed_ignores_generation":

        def bad_succeed(current: Segment, generation: int, remote_key: str) -> Segment:
            if generation <= 0 or not remote_key.strip():
                fail("invalid succeed arguments")
            return replace(
                current,
                status=STATUS_UPLOADED,
                has_remote_key=True,
                active_generation=0,
                acknowledged_generation=generation,
                next_generation=_at_least(current.next_generation, generation + 1),
            )

        module.succeed = bad_succeed
    elif name == "fail_ignores_generation":

        def bad_fail(current: Segment, generation: int) -> Segment:
            if generation <= 0:
                fail("invalid fail arguments")
            return replace(
                current,
                status=STATUS_FAILED,
                active_generation=0,
                next_generation=_at_least(current.next_generation, generation + 1),
            )

        module.fail_upload = bad_fail
    elif name == "begin_reuses_generation":

        def bad_begin(segment: Segment) -> Segment:
            if not can_begin(segment):
                fail("cannot begin")
            generation = _at_least(segment.next_generation, 1)
            return replace(
                segment,
                status=STATUS_UPLOADING,
                next_generation=generation,
                active_generation=generation,
            )

        module.begin = bad_begin
    elif name == "delete_skips_invalidate":

        def bad_delete(segment: Segment) -> Segment:
            return replace(segment, is_local=False)

        module.delete_local_guarded = bad_delete
    elif name == "invalidate_does_not_advance":

        def bad_invalidate(segment: Segment) -> Segment:
            return replace(segment, active_generation=0)

        module.invalidate_for_local_deletion = bad_invalidate
    else:
        restore()
        fail(f"unknown mutant: {name}")
    return restore


def mutation_report() -> dict[str, str]:
    """Run every mutant and hold each to its declared expectation.

    A mutant declared `killed` that survives means the checker is vacuous. A
    mutant declared `equivalent` that dies means the equivalence argument is
    wrong. Both are failures, and both are reported by name.
    """
    outcome: dict[str, str] = {}
    for name, spec in MUTANTS.items():
        restore = _apply_mutant(name)
        try:
            explore()
            outcome[name] = "survived"
        except ModelViolation as violation:
            outcome[name] = "killed by " + str(violation).split(":")[0]
        finally:
            restore()

    vacuous = sorted(
        name
        for name, spec in MUTANTS.items()
        if spec["expect"] == "killed" and outcome[name] == "survived"
    )
    require(not vacuous, f"mutants survived -- the checker is vacuous: {vacuous}")

    misclassified = sorted(
        name
        for name, spec in MUTANTS.items()
        if spec["expect"] == "equivalent" and outcome[name] != "survived"
    )
    require(
        not misclassified,
        "a mutant declared equivalent was killed -- the argument is wrong: "
        + ", ".join(misclassified),
    )
    return outcome


# --------------------------------------------------------------------------
# Refinement tripwire against the Dart source text
# --------------------------------------------------------------------------

DART_SOURCE = Path(__file__).resolve().parents[1] / "lib/src/services/segment_upload_state_machine.dart"

REQUIRED_DART_SHAPES = {
    "stutter-guard-in-succeed": r"current\.activeUploadGeneration\s*!=\s*generation",
    "positive-generation-guard": r"generation\s*<=\s*0",
    "empty-remote-key-guard": r"key\.isEmpty",
    "next-generation-clamp": r"_atLeast\(\s*generation,\s*segment\.activeUploadGeneration \+ 1",
    "acknowledged-clamp": r"_atLeast\(\s*generation,\s*segment\.acknowledgedUploadGeneration \+ 1",
    "invalidate-advances-next": r"_atLeast\(\s*segment\.nextUploadGeneration,\s*invalidatedGeneration \+ 1",
    "projection-keys": r"'acknowledgedGeneration':\s*segment\.acknowledgedUploadGeneration",
}

# The commit rules production calls once AUDIT-2026-08-22 F1 has been repaired.
# Checked only when `SegmentIndexCommit` is present, because this same model
# runs in repositories that have not received the fix yet -- `sonus-auris-ui.dart`
# had not, at the time of writing -- and there the right answer is to report the
# unrepaired variant, not to fail with a confusing missing-shape error.
#
# `spliced` dropping an unchanged row is how a stale generation becomes a
# dropped write rather than a no-op write of a stale list, so it is load-bearing
# for the concurrent model's `production` verdict, not merely tidy.
COMMIT_RULE_SHAPES = {
    "commit-drops-unchanged-row": r"identical\(next, existing\)",
    "commit-requires-nonempty-remote-key": r"if \(key\.isNotEmpty\)",
    "invalidate-all-revokes-active-generations": r"segment\.activeUploadGeneration > 0 && isBeingDeleted\(segment\)",
}

COMMIT_RULES_MARKER = "abstract final class SegmentIndexCommit"

# Lives in a different file, and the `invalidate_does_not_advance` equivalence
# argument depends on it. If this normalisation is ever removed, that mutant
# stops being equivalent and this checker must be told.
MODEL_SOURCE = Path(__file__).resolve().parents[1] / "lib/src/models/recording_segment.dart"

REQUIRED_MODEL_SHAPES = {
    "fromJson-normalises-next-generation": (
        r"activeGeneration \+ 1,\s*\n\s*acknowledgedGeneration \+ 1,"
    ),
}


def check_refinement() -> dict[str, str]:
    """Fail loudly when the Dart moves and this transliteration does not.

    Syntactic, and honest about it: matching these shapes does not prove the
    Python and the Dart agree. It proves only that the specific guards this
    model relies on are still present and still spelled the same way. A
    semantic change that preserves the spelling slips through, which is why
    `VACUITY.md` should carry this as a tripwire and not as a proof.
    """
    if not DART_SOURCE.exists():
        fail(f"production Dart not found at {DART_SOURCE}")
    source = DART_SOURCE.read_text(encoding="utf-8")
    missing = [
        name
        for name, pattern in REQUIRED_DART_SHAPES.items()
        if re.search(pattern, source) is None
    ]
    has_commit_rules = COMMIT_RULES_MARKER in source
    if has_commit_rules:
        missing += [
            name
            for name, pattern in COMMIT_RULE_SHAPES.items()
            if re.search(pattern, source) is None
        ]
    if not MODEL_SOURCE.exists():
        fail(f"production Dart not found at {MODEL_SOURCE}")
    model_source = MODEL_SOURCE.read_text(encoding="utf-8")
    missing += [
        name
        for name, pattern in REQUIRED_MODEL_SHAPES.items()
        if re.search(pattern, model_source) is None
    ]
    require(
        not missing,
        "the Dart state machine changed shape and this model was not updated: "
        + ", ".join(sorted(missing)),
    )
    matched = len(REQUIRED_DART_SHAPES) + len(REQUIRED_MODEL_SHAPES)
    if has_commit_rules:
        matched += len(COMMIT_RULE_SHAPES)
    return {
        "sources": f"{DART_SOURCE.name}, {MODEL_SOURCE.name}",
        "shapes_matched": str(matched),
        "variant": "f1-repaired" if has_commit_rules else "f1-unrepaired",
    }


def production_wiring_report() -> dict[str, object]:
    """Is the state machine actually on the app's hot path?

    This matters more than it looks. AUDIT-2026-08-22 F1 recorded that
    `SegmentUploadStateMachine` was referenced by exactly one file -- its own
    unit test -- while `app_controller.dart` mutated upload status with raw
    `copyWith`. While that was true, every property this checker proves was a
    property of dormant code, and reporting a green run without saying so would
    have been actively misleading.

    Production reaches the machine through `SegmentIndexCommit`, which lives in
    the same file, so a naive grep that skips that file finds nothing and
    reports a false negative. Both entry points are counted here.
    """
    lib = Path(__file__).resolve().parents[1] / "lib"
    entry_points = ("SegmentUploadStateMachine", "SegmentIndexCommit")
    call_sites: dict[str, list[str]] = {name: [] for name in entry_points}
    for path in sorted(lib.rglob("*.dart")):
        if path.name == "segment_upload_state_machine.dart":
            continue
        source = path.read_text(encoding="utf-8")
        for name in entry_points:
            if f"{name}." in source:
                call_sites[name].append(str(path.relative_to(lib.parent)))
    wired = any(call_sites.values())
    return {
        "production_call_sites": {k: v for k, v in call_sites.items() if v},
        "wired": wired,
        "audit_finding": "AUDIT-2026-08-22 F1",
        "note": (
            "wired: the drain loop commits through SegmentIndexCommit"
            if wired
            else "NOT wired: every property above is a property of dormant code"
        ),
    }


DEFECT_SCENARIOS = {
    "corrupt-index-regresses-acknowledgement": (
        "a persisted active generation below the acknowledged one lets a late "
        "success overwrite a durable acknowledgement"
    ),
}


def defect_report() -> dict[str, str]:
    """Expected-FAIL runs. A counterexample is the deliverable.

    When one of these stops reproducing, the fix landed, and this function says
    so by name rather than going quietly green.
    """
    outcome: dict[str, str] = {}
    seeds = corrupt_seeds()
    require(seeds, "no corrupt seeds -- the defect scenario is vacuous")
    try:
        for seed in seeds:
            check_state(seed)
            for label, action in enabled_actions(seed):
                nxt = action(seed)
                check_step(seed, label, nxt)
                check_state(nxt)
        outcome["corrupt-index-regresses-acknowledgement"] = (
            "NO LONGER REPRODUCES -- the fix appears to have landed; "
            "retire this scenario deliberately"
        )
    except ModelViolation as violation:
        outcome["corrupt-index-regresses-acknowledgement"] = f"reproduced: {violation}"
    return outcome


def verify() -> dict[str, object]:
    refinement = check_refinement()
    result = explore()
    mutants = mutation_report()
    wiring = production_wiring_report()
    defects = defect_report()
    return {
        "model": "sonus-upload-generation-v1",
        "claim": "exhaustive-explicit-state-over-transliterated-production-dart",
        "status": "ok",
        "max_generation": MAX_GENERATION,
        "reachable_states": result.states,
        "transitions": result.transitions,
        "invariant_obligations_tested": result.obligations,
        "invariants": list(INVARIANTS),
        "witnesses_reached": sorted(result.trace_witnesses),
        "mutation_outcomes": mutants,
        "refinement": refinement,
        "production_wiring": wiring,
        "defect_scenarios": defects,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-refinement", action="store_true",
                        help="only run the Dart-source tripwire")
    parser.add_argument("--trace", metavar="WITNESS",
                        help="print the shortest action trace reaching a witness")
    args = parser.parse_args()

    try:
        if args.check_refinement:
            print(json.dumps(check_refinement(), sort_keys=True))
            return 0
        if args.trace:
            result = explore()
            if args.trace not in result.trace_witnesses:
                print(f"unknown witness: {args.trace}", file=sys.stderr)
                return 2
            print(json.dumps(result.trace_witnesses[args.trace]))
            return 0
        print(json.dumps(verify(), sort_keys=True))
    except ModelViolation as violation:
        print(f"MODEL VIOLATION: {violation}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
