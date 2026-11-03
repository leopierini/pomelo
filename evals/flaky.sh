#!/bin/bash
# Pomelo's flaky-test sweep (Phase 6): runs the package tests and the app tests several times and prints every test
# that both passed and failed, the 10 slowest tests per suite and any run that died without naming a test.
# Usage: evals/flaky.sh [runs]   (default 3)
# Exit 0: every test gave the same result in every run. Exit 1: an inconsistent test, a test failing in every run,
# or a run that crashed. Exit 2: usage error.
# A flaky test is fixed at its cause (an injected clock, not a longer wait: P134), never deleted or retried.
set -euo pipefail

RUNS="${1:-3}"
case "$RUNS" in ''|*[!0-9]*|0) echo "usage: evals/flaky.sh [runs]" >&2; exit 2 ;; esac
[ "$#" -le 1 ] || { echo "usage: evals/flaky.sh [runs]" >&2; exit 2; }

cd "$(dirname "$0")/.."
BUILD="$HOME/Library/Caches/Pomelo-build"
# Its own derived data: never $BUILD/xcode (the user's app runs from there, P90) and not the evals' folders.
FLAKY_DERIVED="$BUILD/xcode-flaky"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pomelo-flaky.XXXXXX")"
# FLAKY_KEEP_LOGS=<folder> copies the runs' logs there before they are deleted.
trap '[ -z "${FLAKY_KEEP_LOGS:-}" ] || { mkdir -p "$FLAKY_KEEP_LOGS" && cp "$WORK"/*.log "$FLAKY_KEEP_LOGS"/; } || true; rm -rf "$WORK"' EXIT

step() { echo "==> $*"; }

for index in $(seq 1 "$RUNS"); do
    step "package tests, run $index of $RUNS"
    status=0
    swift test --scratch-path "$BUILD" >"$WORK/package-$index.log" 2>&1 || status=$?
    echo "$status" >"$WORK/package-$index.status"
    tail -1 "$WORK/package-$index.log"

    step "app tests, run $index of $RUNS"
    status=0
    xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Debug -derivedDataPath "$FLAKY_DERIVED" \
        test >"$WORK/app-$index.log" 2>&1 || status=$?
    echo "$status" >"$WORK/app-$index.status"
    grep -E "^\*\* TEST (SUCCEEDED|FAILED)" "$WORK/app-$index.log" || tail -3 "$WORK/app-$index.log"
done

step "report"
python3 -I - "$WORK" "$RUNS" <<'PYTHON'
import re
import statistics
import sys
from collections import defaultdict

work, runs = sys.argv[1], int(sys.argv[2])
# swift-testing prints one line per test: "✔ Test name(args:) [with N test cases] passed after 0.123 seconds."
LINE = re.compile(r"^\s*([✔✘]) Test (.+?) (?:with \d+ test cases? )?(passed|failed) after ([0-9.]+) seconds")
problems = 0

for suite in ("package", "app"):
    outcomes = defaultdict(dict)   # test -> run -> "passed" | "failed"
    seconds = defaultdict(list)
    for run in range(1, runs + 1):
        parsed = 0
        with open(f"{work}/{suite}-{run}.log", encoding="utf-8", errors="replace") as log:
            for line in log:
                match = LINE.match(line)
                if not match:
                    continue
                _, name, result, took = match.groups()
                if name.startswith("run with "):   # the bundle's summary line, not a test
                    continue
                parsed += 1
                # The same name in two suites is one entry: a failure in either counts for the run.
                if outcomes[name].get(run) != "failed":
                    outcomes[name][run] = result
                seconds[name].append(float(took))
        if parsed == 0:
            # A changed output format or a run that never started its tests would otherwise report "no flaky test".
            problems += 1
            print(f"{suite} run {run}: no test result parsed from the log; see the run's log")
        status = int(open(f"{work}/{suite}-{run}.status").read())
        failed_here = [n for n, o in outcomes.items() if o.get(run) == "failed"]
        if status != 0 and not failed_here:
            problems += 1
            print(f"{suite} run {run}: exit status {status} with no failing test (build error or crash); see the run's log")

    print(f"\n{suite} tests: {len(outcomes)} distinct, {runs} runs")
    inconsistent = {n: o for n, o in outcomes.items() if len(set(o.values())) > 1}
    always_failed = {n: o for n, o in outcomes.items() if set(o.values()) == {"failed"}}
    for name in sorted(inconsistent):
        problems += 1
        results = ", ".join(f"run {r}: {o}" for r, o in sorted(inconsistent[name].items()))
        print(f"  INCONSISTENT {name} ({results})")
    for name in sorted(always_failed):
        problems += 1
        print(f"  FAILED IN EVERY RUN {name}")
    if not inconsistent and not always_failed:
        print("  no test both passed and failed")

    total = sum(statistics.mean(took) for took in seconds.values())
    how = "they run in parallel" if suite == "package" else "they run one after another"
    print(f"  the tests add up to {total:.1f} s of the suite's wall time ({how})")
    print("  10 slowest (mean over runs):")
    slowest = sorted(seconds.items(), key=lambda item: statistics.mean(item[1]), reverse=True)[:10]
    for name, took in slowest:
        print(f"    {statistics.mean(took):8.3f} s  {name}")

sys.exit(1 if problems else 0)
PYTHON
