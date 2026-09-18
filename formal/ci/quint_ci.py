#!/usr/bin/env python3
"""Manifest-driven glue between the `formal/*.fm.toml` manifests and CI.

Everything CI needs to know about a model is declared in its manifest. This
module reads the manifest and turns it into command-line arguments and
pass/fail judgements, so that a workflow cannot silently drift away from the
manifest by hardcoding a list that the manifest no longer agrees with.

Three judgements live here, and each one exists because the naive version of
it is a check that passes without proving anything:

  `witnesses`   A witness is a reachability obligation. `quint run --witnesses`
                reports how many traces reached each one and then exits 0
                regardless, so a witness that has become unreachable -- because
                a guard was tightened, or the model rotted -- is invisible
                unless something reads the report. `assert-witnesses` reads it.

  `defects`     A `defect_invariants` entry is expected to FAIL. Under that
                convention a model that has rotted into vacuity reports success
                on every defect invariant and reads as a row of fixed bugs.
                `assert-defect` inverts the judgement and prints a distinct
                message for the unexpected pass, so the two cases can never be
                confused.

  `toolchain`   The manifest pins a quint version and the workflow installs
                one. `assert-toolchain` fails when they disagree.

Run `python3 formal/ci/quint_ci.py self-test` to exercise every parser in this
file against recorded fixtures. CI runs it before trusting any judgement below.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

# `quint run --witnesses a b c` prints a "Witnesses:" block of lines shaped
# like `name was witnessed in 12 trace(s) out of 10000 explored (0.12%)`.
# The count is the only thing that matters; the surrounding prose is matched
# loosely so a cosmetic change upstream does not turn into a false failure --
# but a witness whose line cannot be found at all is an error, never a pass.
_WITNESS_LINE = re.compile(
    r"^\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b.*?\b(?P<count>\d+)\s+trace", re.MULTILINE
)

# `quint run`/`quint verify` mark their verdict with a bracketed tag. A run
# that produced neither tag did not reach a verdict (bad CLI arguments, a
# parse error, an OOM), which is a distinct outcome from "no counterexample".
_VIOLATION = re.compile(r"\[violation\]", re.IGNORECASE)
_OK = re.compile(r"\[ok\]", re.IGNORECASE)

_VERSION = re.compile(r"(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)")


class CheckFailed(SystemExit):
    def __init__(self, message: str) -> None:
        super().__init__(f"::error::{message}")


def load_manifest(path: Path, machine: str | None = None) -> dict[str, Any]:
    """Read a manifest and normalise it to one shape.

    Two manifest schemas exist in this estate and both are read here, so that
    one set of CI judgements covers every repository:

      flat        `formal/fm.toml` -- one model per file, keys at top level.
      per-machine `formal.toml` -- `[[machine]]` entries selected by `name`,
                  with bounds under `[machine.bounds]` and the nightly
                  exhaustive profile under `[machine.nightly]`.

    Passing `--machine NAME` selects and normalises the second form; without
    it the document is returned as-is.
    """
    with path.open("rb") as handle:
        document = tomllib.load(handle)
    if machine is None:
        return document

    entries = document.get("machine")
    if not isinstance(entries, list) or not entries:
        raise CheckFailed(f"{path} declares no [[machine]] entries")
    for entry in entries:
        if entry.get("name") == machine:
            bounds = entry.get("bounds", {})
            nightly = entry.get("nightly", {})
            return {
                "model": entry.get("name"),
                "spec": entry.get("model"),
                "tests": entry.get("tests"),
                "main": entry.get("main"),
                "invariants": entry.get("invariants", []),
                "defect_invariants": entry.get("defect_invariants", []),
                "witnesses": entry.get("witnesses", []),
                "toolchain": entry.get("toolchain", {}),
                "simulation": {
                    "max_samples": bounds.get("max_samples"),
                    "max_steps": bounds.get("max_steps"),
                },
                "verification": {"max_steps": nightly.get("max_steps", bounds.get("max_steps"))},
            }
    known = ", ".join(sorted(str(entry.get("name")) for entry in entries))
    raise CheckFailed(f"{path} has no [[machine]] named {machine!r}; it declares: {known}")


# ---------------------------------------------------------------------------
# Parsers (pure functions, exercised by self-test)
# ---------------------------------------------------------------------------


def parse_witness_counts(log: str) -> dict[str, int]:
    """Map every reported witness name to the number of traces that reached it."""
    counts: dict[str, int] = {}
    for match in _WITNESS_LINE.finditer(log):
        name = match.group("name")
        # First report wins; quint prints each witness once.
        counts.setdefault(name, int(match.group("count")))
    return counts


def classify_verdict(log: str, exit_status: int) -> str:
    """Return 'violation', 'ok', or 'inconclusive' for a quint run/verify log.

    `inconclusive` covers every way the checker can terminate without reaching
    a verdict. It is deliberately NOT folded into either of the other two: a
    crashed checker must never be reported as a proof and must never be
    reported as a counterexample.
    """
    if _VIOLATION.search(log):
        return "violation"
    if _OK.search(log) and exit_status == 0:
        return "ok"
    return "inconclusive"


def parse_version(text: str) -> str | None:
    match = _VERSION.search(text.strip())
    return match.group(1) if match else None


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def _string_list(manifest: dict[str, Any], key: str) -> list[str]:
    value = manifest.get(key, [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise CheckFailed(f"manifest key {key!r} must be a list of strings")
    return value


def cmd_field(args: argparse.Namespace) -> int:
    manifest = load_manifest(Path(args.manifest), getattr(args, 'machine', None))
    node: Any = manifest
    for part in args.key.split("."):
        if not isinstance(node, dict) or part not in node:
            raise CheckFailed(f"{args.manifest} has no key {args.key!r}")
        node = node[part]
    if isinstance(node, list):
        print("\n".join(str(item) for item in node))
    else:
        print(node)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    """Print one entry per line. Empty output (and exit 0) means an empty list.

    `--require-nonempty` turns an empty list into a failure, which is what the
    witness and defect steps use: a manifest that has quietly lost its
    obligations must not read as a workflow with nothing to do.
    """
    manifest = load_manifest(Path(args.manifest), getattr(args, 'machine', None))
    entries = _string_list(manifest, args.key)
    if args.require_nonempty and not entries:
        raise CheckFailed(
            f"{args.manifest} declares no {args.key!r}; CI drives this step from the "
            f"manifest, so an empty list would silently check nothing"
        )
    print("\n".join(entries))
    return 0


def cmd_assert_toolchain(args: argparse.Namespace) -> int:
    manifest = load_manifest(Path(args.manifest), getattr(args, 'machine', None))
    pinned = manifest.get("toolchain", {}).get("quint")
    if not isinstance(pinned, str) or not pinned.strip():
        raise CheckFailed(f"{args.manifest} does not pin [toolchain] quint")
    actual = parse_version(args.actual)
    if actual is None:
        raise CheckFailed(
            f"could not read a version out of `quint --version` output: {args.actual!r}"
        )
    if actual != pinned:
        raise CheckFailed(
            f"toolchain drift: {args.manifest} pins quint = {pinned!r} but the "
            f"installed quint reports {actual!r}. Every bound, every counterexample "
            f"and every 'verified' claim in that manifest was recorded against "
            f"{pinned!r}. Update the manifest and the workflow together, or pin back."
        )
    print(f"quint {actual} matches the pin in {args.manifest}")
    return 0


def cmd_assert_witnesses(args: argparse.Namespace) -> int:
    manifest = load_manifest(Path(args.manifest), getattr(args, 'machine', None))
    expected = _string_list(manifest, "witnesses")
    if not expected:
        raise CheckFailed(f"{args.manifest} declares no witnesses to check")
    log = Path(args.log).read_text(encoding="utf-8", errors="replace")
    counts = parse_witness_counts(log)

    unreached: list[str] = []
    unreported: list[str] = []
    reached: list[tuple[str, int]] = []
    for name in expected:
        if name not in counts:
            unreported.append(name)
        elif counts[name] == 0:
            unreached.append(name)
        else:
            reached.append((name, counts[name]))

    for name, count in reached:
        print(f"witness reached: {name} ({count} trace(s))")

    problems: list[str] = []
    if unreported:
        problems.append(
            "quint reported no result for these declared witnesses: "
            + ", ".join(unreported)
            + ". Either the name does not exist in the model (a manifest that names a "
            "witness the model does not define checks nothing), or the witness report "
            "was not produced at all."
        )
    if unreached:
        problems.append(
            "these declared witnesses were never reached: "
            + ", ".join(unreached)
            + ". A witness is a reachability obligation: an unreachable one means the "
            "state it names can no longer occur, so every property proved about that "
            "state is now vacuous. Raise [simulation] max_samples/max_steps in the "
            "manifest if the state is merely rare, or remove the witness and say why."
        )
    if problems:
        raise CheckFailed(" ".join(problems))

    print(f"all {len(expected)} declared witnesses were reached")
    return 0


def cmd_assert_defect(args: argparse.Namespace) -> int:
    """Judge one `defect_invariants` entry, where a counterexample is the deliverable."""
    log = Path(args.log).read_text(encoding="utf-8", errors="replace")
    verdict = classify_verdict(log, args.status)

    if verdict == "violation":
        print(
            f"defect confirmed: {args.name} produced a counterexample, as the manifest "
            f"declares it should"
        )
        return 0

    if verdict == "ok":
        raise CheckFailed(
            f"UNEXPECTED PASS on defect invariant {args.name}: the checker found no "
            f"counterexample. This either means the defect was fixed -- in which case "
            f"promote {args.name} out of `defect_invariants` into `invariants` in the "
            f"manifest and record the fix -- or the model has gone vacuous and the "
            f"defective trace is no longer reachable. It is NOT a passing check. "
            f"Under this manifest's expected-failure convention a green result here is "
            f"indistinguishable from model rot until a human says which one it is."
        )

    raise CheckFailed(
        f"INCONCLUSIVE on defect invariant {args.name}: the checker exited "
        f"{args.status} without printing either an [ok] or a [violation] verdict, so "
        f"it did not reach a conclusion. Treated as a failure, because a checker that "
        f"crashed proves nothing in either direction. See the log for the cause."
    )


def cmd_assert_invariant(args: argparse.Namespace) -> int:
    """Judge one ordinary invariant, where a counterexample is a failure."""
    log = Path(args.log).read_text(encoding="utf-8", errors="replace")
    verdict = classify_verdict(log, args.status)
    if verdict == "ok":
        print(f"invariant holds: {args.name}")
        return 0
    if verdict == "violation":
        raise CheckFailed(
            f"invariant {args.name} was violated; the counterexample is in the log and "
            f"in the uploaded ITF artifact"
        )
    raise CheckFailed(
        f"INCONCLUSIVE on invariant {args.name}: the checker exited {args.status} "
        f"without printing an [ok] or [violation] verdict. A checker that did not "
        f"reach a verdict must not be recorded as a proof."
    )


def cmd_summary(args: argparse.Namespace) -> int:
    """Emit a markdown block stating what this event actually checked."""
    manifest = load_manifest(Path(args.manifest), getattr(args, 'machine', None))
    name = manifest.get("model", args.manifest)
    invariants = ", ".join(_string_list(manifest, "invariants")) or "(none)"
    defects = _string_list(manifest, "defect_invariants")
    witnesses = _string_list(manifest, "witnesses")
    # Whether the exhaustive checker ran is a property of the workflow, not of
    # the event: a cheap model can afford Apalache on pull requests and a wide
    # one cannot. `--apalache` lets the workflow state which it did, so this
    # table can never claim a check the run did not perform.
    choice = getattr(args, "apalache", "auto")
    apalache_ran = (args.event != "pull_request") if choice == "auto" else (choice == "run")

    lines = [
        f"### {name}",
        "",
        f"| check | this `{args.event}` run |",
        "| --- | --- |",
        "| typecheck + deterministic traces | run |",
        f"| randomized simulation of `{invariants}` | run ({manifest.get('simulation', {}).get('max_samples', '?')} samples) |",
        f"| reachability of {len(witnesses)} declared witnesses | enforced |",
        (
            f"| bounded exhaustive verification (Apalache, "
            f"{manifest.get('verification', {}).get('max_steps', '?')} steps) | "
            + ("run |" if apalache_ran else "**NOT RUN in this job** |")
        ),
    ]
    if defects:
        lines.append(
            f"| {len(defects)} declared defect invariants must each produce a counterexample | "
            + ("enforced |" if apalache_ran else "**NOT CHECKED in this job** |")
        )
    if not apalache_ran and defects:
        lines += [
            "",
            "> Apalache needs a JVM and minutes per invariant, so this job gets "
            "randomized simulation only. The defect-invariant judgement is deliberately "
            "not attempted here: simulation failing to find a known counterexample is "
            "not evidence that the defect was fixed, and reporting it as one would be "
            "exactly the confusion this job exists to prevent. Those obligations are "
            "checked on every push to `main`, on the weekly schedule, and on manual "
            "dispatch.",
        ]
    print("\n".join(lines))
    return 0


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

_FIXTURE_RUN_OK = """\
[ok] No violation found (2451ms).
Witnesses:
direct_upload_reached was witnessed in 8134 trace(s) out of 10000 explored (81.34%)
retention_tombstone_reached was witnessed in 12 trace(s) out of 10000 explored (0.12%)
unbacked_retention_failure_reached was witnessed in 0 trace(s) out of 10000 explored (0.00%)
Use --verbosity=3 to show executions.
"""

_FIXTURE_VERIFY_VIOLATION = """\
[violation] Found an issue (18321ms).
Use --verbosity=3 to show executions.
error: Invariant violated
"""

_FIXTURE_VERIFY_OK = "[ok] No violation found (9210ms).\n"

_FIXTURE_CRASH = """\
error: Cannot find module '@informalsystems/quint/dist/apalache'
Command failed with exit code 1.
"""


def _expect(condition: bool, label: str) -> None:
    if not condition:
        raise AssertionError(f"self-test failed: {label}")


def cmd_self_test(_: argparse.Namespace) -> int:
    counts = parse_witness_counts(_FIXTURE_RUN_OK)
    _expect(counts["direct_upload_reached"] == 8134, "reached witness count")
    _expect(counts["retention_tombstone_reached"] == 12, "rare witness count")
    _expect(counts["unbacked_retention_failure_reached"] == 0, "unreached witness count")
    _expect("Witnesses" not in counts, "the block header is not a witness")

    _expect(classify_verdict(_FIXTURE_RUN_OK, 0) == "ok", "ok verdict")
    _expect(classify_verdict(_FIXTURE_VERIFY_VIOLATION, 1) == "violation", "violation verdict")
    _expect(classify_verdict(_FIXTURE_VERIFY_OK, 0) == "ok", "verify ok verdict")
    _expect(classify_verdict(_FIXTURE_CRASH, 1) == "inconclusive", "crash is inconclusive")
    # A non-zero exit with an [ok] tag is still not a proof.
    _expect(classify_verdict(_FIXTURE_VERIFY_OK, 137) == "inconclusive", "killed run")

    _expect(parse_version("0.32.0") == "0.32.0", "bare version")
    _expect(parse_version("quint v0.32.0\n") == "0.32.0", "prefixed version")
    _expect(parse_version("no digits here") is None, "unparseable version")

    # The judgements themselves, driven through the same entry points CI uses.
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log"

        log.write_text(_FIXTURE_VERIFY_VIOLATION, encoding="utf-8")
        args = argparse.Namespace(name="epoch_isolation", log=str(log), status=1)
        _expect(cmd_assert_defect(args) == 0, "expected defect counterexample accepted")

        log.write_text(_FIXTURE_VERIFY_OK, encoding="utf-8")
        args = argparse.Namespace(name="epoch_isolation", log=str(log), status=0)
        try:
            cmd_assert_defect(args)
        except CheckFailed as error:
            _expect("UNEXPECTED PASS" in str(error), "unexpected pass is named as such")
        else:
            raise AssertionError("self-test failed: a passing defect invariant must fail CI")

        log.write_text(_FIXTURE_CRASH, encoding="utf-8")
        args = argparse.Namespace(name="epoch_isolation", log=str(log), status=1)
        try:
            cmd_assert_defect(args)
        except CheckFailed as error:
            _expect("INCONCLUSIVE" in str(error), "crash is not read as a counterexample")
        else:
            raise AssertionError("self-test failed: a crashed checker must fail CI")

        log.write_text(_FIXTURE_VERIFY_OK, encoding="utf-8")
        args = argparse.Namespace(name="segment_lifecycle_safety", log=str(log), status=0)
        _expect(cmd_assert_invariant(args) == 0, "holding invariant accepted")

        log.write_text(_FIXTURE_VERIFY_VIOLATION, encoding="utf-8")
        args = argparse.Namespace(name="segment_lifecycle_safety", log=str(log), status=1)
        try:
            cmd_assert_invariant(args)
        except CheckFailed:
            pass
        else:
            raise AssertionError("self-test failed: a violated invariant must fail CI")

        # Witness enforcement against a manifest, including the unreachable case.
        manifest = Path(tmp) / "fm.toml"
        manifest.write_text(
            'witnesses = ["direct_upload_reached", "retention_tombstone_reached"]\n',
            encoding="utf-8",
        )
        log.write_text(_FIXTURE_RUN_OK, encoding="utf-8")
        args = argparse.Namespace(manifest=str(manifest), log=str(log))
        _expect(cmd_assert_witnesses(args) == 0, "reachable witnesses accepted")

        manifest.write_text(
            'witnesses = ["unbacked_retention_failure_reached"]\n', encoding="utf-8"
        )
        try:
            cmd_assert_witnesses(args)
        except CheckFailed as error:
            _expect("never reached" in str(error), "unreachable witness names itself")
        else:
            raise AssertionError("self-test failed: an unreachable witness must fail CI")

        manifest.write_text('witnesses = ["a_witness_the_model_lost"]\n', encoding="utf-8")
        try:
            cmd_assert_witnesses(args)
        except CheckFailed as error:
            _expect("no result" in str(error), "unreported witness names itself")
        else:
            raise AssertionError("self-test failed: an unreported witness must fail CI")

        # Toolchain pin.
        manifest.write_text('[toolchain]\nquint = "0.32.0"\n', encoding="utf-8")
        _expect(
            cmd_assert_toolchain(
                argparse.Namespace(manifest=str(manifest), actual="0.32.0")
            )
            == 0,
            "matching pin accepted",
        )
        try:
            cmd_assert_toolchain(argparse.Namespace(manifest=str(manifest), actual="0.33.1"))
        except CheckFailed as error:
            _expect("toolchain drift" in str(error), "drift names itself")
        else:
            raise AssertionError("self-test failed: toolchain drift must fail CI")

        # The per-machine `formal.toml` schema, normalised to the same shape.
        machine_manifest = Path(tmp) / "formal.toml"
        machine_manifest.write_text(
            "schema = 1\n"
            "\n"
            "[[machine]]\n"
            'name = "hlc-conflict-retry"\n'
            'model = "formal/models/hlc_conflict_retry.qnt"\n'
            'main = "hlc_conflict_retry"\n'
            'invariants = ["hlc_conflict_retry_safety"]\n'
            'witnesses = ["counter_carry_reached"]\n'
            "\n"
            "[machine.toolchain]\n"
            'quint = "0.32.0"\n'
            "\n"
            "[machine.bounds]\n"
            "max_steps = 3\n"
            "max_samples = 10000\n"
            "\n"
            "[machine.nightly]\n"
            "max_steps = 3\n",
            encoding="utf-8",
        )
        normalised = load_manifest(machine_manifest, "hlc-conflict-retry")
        _expect(normalised["main"] == "hlc_conflict_retry", "machine main")
        _expect(normalised["witnesses"] == ["counter_carry_reached"], "machine witnesses")
        _expect(normalised["simulation"]["max_samples"] == 10000, "machine bounds -> simulation")
        _expect(normalised["verification"]["max_steps"] == 3, "machine nightly -> verification")
        _expect(
            cmd_assert_toolchain(
                argparse.Namespace(
                    manifest=str(machine_manifest),
                    machine="hlc-conflict-retry",
                    actual="quint v0.32.0",
                )
            )
            == 0,
            "per-machine toolchain pin",
        )
        try:
            load_manifest(machine_manifest, "no-such-machine")
        except CheckFailed as error:
            _expect("has no [[machine]] named" in str(error), "unknown machine names itself")
        else:
            raise AssertionError("self-test failed: an unknown machine name must fail CI")

        # The summary table must follow what the job did, not the event name.
        flat = Path(tmp) / "summary.fm.toml"
        flat.write_text(
            'model = "m"\ninvariants = ["safe"]\nwitnesses = ["w"]\n'
            'defect_invariants = ["d"]\n',
            encoding="utf-8",
        )
        import contextlib
        import io

        def render(event: str, apalache: str) -> str:
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                cmd_summary(
                    argparse.Namespace(
                        manifest=str(flat), machine=None, event=event, apalache=apalache
                    )
                )
            return buffer.getvalue()

        _expect("NOT RUN" in render("pull_request", "auto"), "auto skips on pull_request")
        _expect("NOT RUN" not in render("push", "auto"), "auto runs on push")
        _expect("NOT RUN" not in render("pull_request", "run"), "override says it ran")
        _expect("NOT RUN" in render("push", "skipped"), "override says it did not run")

    print("quint_ci self-test: all parser and judgement cases passed")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    machine_help = "select a [[machine]] by name in a per-machine formal.toml"

    p = sub.add_parser("field", help="print one manifest value")
    p.add_argument("--manifest", required=True)
    p.add_argument("--machine", default=None, help=machine_help)
    p.add_argument("--key", required=True)
    p.set_defaults(func=cmd_field)

    p = sub.add_parser("list", help="print a manifest string list, one per line")
    p.add_argument("--manifest", required=True)
    p.add_argument("--machine", default=None, help=machine_help)
    p.add_argument("--key", required=True)
    p.add_argument("--require-nonempty", action="store_true")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("assert-toolchain", help="fail if the installed quint is not the pin")
    p.add_argument("--manifest", required=True)
    p.add_argument("--machine", default=None, help=machine_help)
    p.add_argument("--actual", required=True)
    p.set_defaults(func=cmd_assert_toolchain)

    p = sub.add_parser("assert-witnesses", help="fail if a declared witness was not reached")
    p.add_argument("--manifest", required=True)
    p.add_argument("--machine", default=None, help=machine_help)
    p.add_argument("--log", required=True)
    p.set_defaults(func=cmd_assert_witnesses)

    p = sub.add_parser("assert-defect", help="fail unless this invariant produced a counterexample")
    p.add_argument("--name", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--status", type=int, required=True)
    p.set_defaults(func=cmd_assert_defect)

    p = sub.add_parser("assert-invariant", help="fail unless this invariant held")
    p.add_argument("--name", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--status", type=int, required=True)
    p.set_defaults(func=cmd_assert_invariant)

    p = sub.add_parser("summary", help="markdown stating what this event checked")
    p.add_argument("--manifest", required=True)
    p.add_argument("--machine", default=None, help=machine_help)
    p.add_argument("--event", required=True)
    p.add_argument(
        "--apalache",
        choices=("run", "skipped", "auto"),
        default="auto",
        help="whether this job actually ran the exhaustive checker "
        "(default: infer from the event, skipped on pull_request)",
    )
    p.set_defaults(func=cmd_summary)

    p = sub.add_parser("self-test", help="exercise every parser and judgement here")
    p.set_defaults(func=cmd_self_test)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
