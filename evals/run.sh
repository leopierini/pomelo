#!/bin/bash
# Pomelo's measurement harness (P29). Usage: evals/run.sh [--quick] [--update-baseline]
#   --quick            skip the clean builds, the warning counts and the test runs
#   --update-baseline  rewrite evals/baseline.json with this run's values (say why in the commit message)
# Exit 0: no regression. Exit 1: a regression or a failed check. Exit 2: usage error.
set -euo pipefail

QUICK=0
UPDATE=0
AUDIT_ARGS=()
for argument in "$@"; do
    case "$argument" in
        --quick) QUICK=1 ;;
        --update-baseline) UPDATE=1 ;;
        *) echo "usage: evals/run.sh [--quick] [--update-baseline]" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
. evals/harness.sh
BUILD="$HOME/Library/Caches/Pomelo-build"
EVALS_SCRATCH="$BUILD/evals"
EVALS_DERIVED="$BUILD/xcode-evals"
EVALS_DEBUG_DERIVED="$BUILD/xcode-evals-debug"
APP="$EVALS_DERIVED/Build/Products/Release/PomeloEvals.app"
APP_BINARY="$APP/Contents/MacOS/PomeloEvals"
CLI="$EVALS_SCRATCH/release/pomelo"
EVALS="$EVALS_SCRATCH/release/pomelo-evals"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pomelo-evals.XXXXXX")"
# xctrace stops the target as it exits and detaches without resuming it, which strands a stopped process, and it
# resolves the app by name, so it may have launched another copy of it than $APP_BINARY. The pattern is anchored on
# this run's work folder in the arguments, so it matches what this run started from any copy and never an installed
# Pomelo (see reap_started_under).
reap_measured_app() { reap_started_under "$WORK"; }
KTRACE_CLAIMS="$WORK/ktrace-claims"
trap 'reap_measured_app; remove_claimed_ktraces; rm -rf "$WORK"' EXIT
# The measured app is re-signed ad hoc on every build, so macOS asks again each time it reads a protected folder
# (Desktop, Documents, Downloads, iCloud Drive, File Provider folders) and the prompt lands on the user's screen.
# Every path it is given lives in $WORK, and it runs with $WORK as its working directory (P60), so it never inherits
# the repo.
assert_app_path_is_unprotected() {
    local resolved
    resolved="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
    case "$resolved" in
        "$HOME"/Desktop/*|"$HOME"/Documents/*|"$HOME"/Downloads/*|"$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/"*)
            echo "refusing to pass $resolved to the measured app: it would trigger a privacy prompt" >&2
            exit 1 ;;
    esac
}
mkdir -p evals/results
RESULTS="evals/results/$(date +%Y-%m-%d-%H%M).json"

step() { echo "==> $*"; }
# swift-testing prints one "Test run with N tests ... passed after S seconds" per test bundle: "total-N total-S".
test_summary() {
    sed -nE 's/.*Test run with ([0-9]+) tests?.* passed after ([0-9.]+) seconds.*/\1 \2/p' "$1" \
        | awk '{ count += $1; seconds += $2 } END { printf "%d %.3f\n", count, seconds }'
}

if [ "$QUICK" -eq 0 ]; then
    step "clean build folders"
    rm -rf "$EVALS_SCRATCH" "$EVALS_DERIVED" "$EVALS_DEBUG_DERIVED"
fi

step "build the CLI and pomelo-evals (release)"
swift build -c release --scratch-path "$EVALS_SCRATCH" 2>&1 | tee "$WORK/package-build.log" | tail -3

step "corpus"
"$EVALS" corpus evals/corpus
# The CLI edges read evals/corpus (the CLI runs with the terminal's access); the app gets its own copy.
APP_CORPUS="$WORK/app-corpus"
mkdir -p "$APP_CORPUS"
cp evals/corpus/photo.png "$APP_CORPUS/photo.png"
cp evals/corpus/photo.jpg "$APP_CORPUS/photo.jpg"
cp evals/corpus/clip.mov "$APP_CORPUS/clip.mov"
cp evals/corpus/doc.pdf "$APP_CORPUS/doc.pdf"
cp evals/corpus/photo.heic "$APP_CORPUS/photo.heic"
cp evals/settings/custom-wheel.json "$APP_CORPUS/custom-wheel.json"
WATCHED="$WORK/watched"
mkdir -p "$WATCHED"
# $WORK itself too: it is the measured app's working directory (P60).
for path in "$WORK" "$APP_CORPUS/photo.png" "$APP_CORPUS/photo.jpg" "$APP_CORPUS/clip.mov" "$APP_CORPUS/doc.pdf" \
        "$APP_CORPUS/photo.heic" "$APP_CORPUS/custom-wheel.json" "$WATCHED" "$WORK/idle.json" "$WORK/shelf-idle" "$WORK/shelf-idle.json" "$WORK/watch.json" "$WORK/hook.json" "$WORK/hook-custom.json" "$WORK/shelf-open.json" "$WORK/editor.json" \
        "$WORK/editor-trim.json" "$WORK/editor-crop.json" "$WORK/editor-redact.json" "$WORK/editor-pages.json" \
        "$WORK/editor-resize.json" "$WORK/editor-rotate.json" \
        "$APP_CORPUS" "$WORK/a11y.json"; do
    assert_app_path_is_unprotected "$path"
done
LAUNCHES=10
for index in $(seq 1 "$LAUNCHES"); do assert_app_path_is_unprotected "$WORK/launch-$index.json"; done

step "build the app (release, with the eval hooks)"
# POMELO_BUNDLE_IDENTIFIER, not PRODUCT_BUNDLE_IDENTIFIER: a command-line setting reaches every target, and the
# Quick Action's identifier must be the app's plus ".QuickAction".
xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Release -derivedDataPath "$EVALS_DERIVED" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) POMELO_EVALS' \
    POMELO_BUNDLE_IDENTIFIER=io.github.pomelo-app.Pomelo.evals POMELO_PRODUCT_NAME=PomeloEvals build >"$WORK/app-build.log" 2>&1 \
    || { tail -30 "$WORK/app-build.log"; exit 1; }

step "bundle structure"
"$EVALS" bundle --app "$APP" --entitlements App --cli "$CLI" --out "$WORK/bundle.json"

# Idle comes before xctrace: measured after it, wakeups read 3.7 to 17.8 per second against 0.4 for the same binary
# run directly (P45). The settle lets the build's last disk and indexing work die down.
step "idle (30 s)"
sleep 5
(cd "$WORK" && "$APP_BINARY" --eval-idle 30 "$WORK/idle.json")
reap_measured_app

# S26: a Shelf holding 200 files, off-screen, costs no more than the app at rest; before xctrace for the same reason.
step "shelf idle"
(cd "$WORK" && "$APP_BINARY" --eval-shelf-idle "$WORK/shelf-idle" 20 "$WORK/shelf-idle.json")
reap_measured_app

# Also before xctrace, for the same reason: its quiet wakeups are compared with idle's.
step "watch folder (10 s quiet, then 10 arrivals)"
(cd "$WORK" && "$APP_BINARY" --eval-watch "$WATCHED" "$APP_CORPUS/photo.heic" 10 "$WORK/watch.json")
reap_measured_app

# After idle and watch, so its launches never disturb their quiet; before xctrace, which leaves the machine noisy (P45).
step "launch ($LAUNCHES times)"
: >"$WORK/launch-samples.txt"
for index in $(seq 1 "$LAUNCHES"); do
    (cd "$WORK" && "$APP_BINARY" --eval-launch "$WORK/launch-$index.json")
    reap_measured_app
    echo "$WORK/launch-$index.json" >>"$WORK/launch-samples.txt"
done

step "wheel open"
HOOK="$WORK/hook.json"
SIGNPOST_ARGS=()
# xctrace has hung past its own --time-limit twice, so it also runs under a hard deadline that kills it by PID.
XCTRACE_DEADLINE="${POMELO_XCTRACE_DEADLINE:-120}"
: >"$KTRACE_CLAIMS"
pushd "$WORK" >/dev/null
RECORDED=0
run_with_deadline "$XCTRACE_DEADLINE" xcrun xctrace record --template Logging --no-prompt --time-limit 60s \
    --output "$WORK/wheel.trace" --launch -- \
    "$APP_BINARY" --eval-wheel-open "$APP_CORPUS/photo.png" 200 "$HOOK" >"$WORK/xctrace.log" 2>&1 || RECORDED=$?
if [ "$RECORDED" -eq 124 ]; then
    reap_measured_app
    echo "xctrace hung: killed after ${XCTRACE_DEADLINE} s. Its log:" >&2
    tail -5 "$WORK/xctrace.log" >&2
    exit 1
fi
if [ "$RECORDED" -eq 0 ] && [ -f "$HOOK" ] \
    && run_with_deadline 60 xcrun xctrace export --input "$WORK/wheel.trace" --toc --output "$WORK/toc.xml" >>"$WORK/xctrace.log" 2>&1 \
    && run_with_deadline 60 xcrun xctrace export --input "$WORK/wheel.trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
        --output "$WORK/signpost.xml" >>"$WORK/xctrace.log" 2>&1; then
    # xctrace launches the app by name, so with a second copy on disk (a worktree build, an old build folder) it can
    # time that one instead: the trace says which binary ran.
    TRACED_APP="$(traced_app_path "$WORK/toc.xml")" || TRACED_APP=""
    if ! same_location "$TRACED_APP" "$APP"; then
        echo "xctrace timed '${TRACED_APP:-an unknown app}', not the evals build '$APP'. Remove the other copy of PomeloEvals.app and run again." >&2
        exit 1
    fi
    SIGNPOST_ARGS=(--signpost-export "$WORK/signpost.xml")
else
    echo "xctrace could not record; using the app's own clock for the wheel"
    "$APP_BINARY" --eval-wheel-open "$APP_CORPUS/photo.png" 200 "$HOOK"
fi
popd >/dev/null
reap_measured_app
remove_claimed_ktraces

# Own file, never $HOOK: the results step reads that one for wheel.open.* (P181). The same 50 ms rule holds for a
# customized wheel, whose open also resolves every slot's availability, so it is measured by the app's own clock.
step "wheel open (customized)"
(cd "$WORK" && "$APP_BINARY" --eval-wheel-open "$APP_CORPUS/photo.png" 200 "$WORK/hook-custom.json" "$APP_CORPUS/custom-wheel.json")
reap_measured_app

# S27: a shake's Shelf appears on a poll tick mid-drag, so it gets the wheel's 33.3 ms budget.
step "shelf open"
(cd "$WORK" && "$APP_BINARY" --eval-shelf-open "$APP_CORPUS/photo.png" 200 "$WORK/shelf-open.json")
reap_measured_app

step "editor open (Compress to size)"
(cd "$WORK" && "$APP_BINARY" --eval-editor-open targetSize "$APP_CORPUS/photo.jpg" 100 "$WORK/editor.json")
reap_measured_app

step "editor open (Trim)"
(cd "$WORK" && "$APP_BINARY" --eval-editor-open trim "$APP_CORPUS/clip.mov" 100 "$WORK/editor-trim.json")
reap_measured_app

step "editor open (Crop)"
(cd "$WORK" && "$APP_BINARY" --eval-editor-open crop "$APP_CORPUS/photo.png" 100 "$WORK/editor-crop.json")
reap_measured_app

step "editor open (Redact)"
(cd "$WORK" && "$APP_BINARY" --eval-editor-open redact "$APP_CORPUS/photo.jpg" 100 "$WORK/editor-redact.json")
reap_measured_app

step "editor open (Organize pages)"
(cd "$WORK" && "$APP_BINARY" --eval-editor-open organizePages "$APP_CORPUS/doc.pdf" 100 "$WORK/editor-pages.json")
reap_measured_app

step "editor open (Resize)"
(cd "$WORK" && "$APP_BINARY" --eval-editor-open resize "$APP_CORPUS/photo.png" 100 "$WORK/editor-resize.json")
reap_measured_app

step "editor open (Rotate)"
(cd "$WORK" && "$APP_BINARY" --eval-editor-open rotate "$APP_CORPUS/photo.png" 100 "$WORK/editor-rotate.json")
reap_measured_app

# P146: the app walks its own windows' AppKit views (SwiftUI builds its tree only for a connected assistive app), and
# the lint reads the SwiftUI source; the metric is their sum.
step "accessibility (walk and lint)"
(cd "$WORK" && "$APP_BINARY" --eval-accessibility "$APP_CORPUS" "$WORK/a11y.json")
reap_measured_app
"$EVALS" a11y-lint --sources App/Sources App/QuickAction --out "$WORK/a11y-lint.json"
A11Y_WALK="$(plutil -extract count raw -o - "$WORK/a11y.json")"
A11Y_LINT="$(plutil -extract count raw -o - "$WORK/a11y-lint.json")"
[ "$A11Y_WALK" -eq 0 ] || plutil -p "$WORK/a11y.json"

step "sizes"
kilobytes() { echo $(( $(stat -f%z "$1") / 1024 )); }
METRICS=(
    --metric "app.bundle_kb=$(du -sk "$APP" | cut -f1)"
    --metric "app.binary_kb=$(kilobytes "$APP_BINARY")"
    --metric "cli.binary_kb=$(kilobytes "$CLI")"
    --metric "shelf.open.p50_ms=$(plutil -extract p50Ms raw -o - "$WORK/shelf-open.json")"
    --metric "shelf.open.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/shelf-open.json")"
    --metric "editor.open.targetSize.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/editor.json")"
    --metric "editor.open.trim.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/editor-trim.json")"
    --metric "editor.open.crop.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/editor-crop.json")"
    --metric "editor.open.redact.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/editor-redact.json")"
    --metric "editor.open.organizePages.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/editor-pages.json")"
    --metric "editor.open.resize.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/editor-resize.json")"
    --metric "editor.open.rotate.p95_ms=$(plutil -extract p95Ms raw -o - "$WORK/editor-rotate.json")"
    --metric "app.watch.latency.p95_ms=$(plutil -extract latencyP95Ms raw -o - "$WORK/watch.json")"
    --metric "app.watch.idle.wakeups_per_s=$(plutil -extract idleWakeupsPerSecond raw -o - "$WORK/watch.json")"
    --metric "app.shelf.idle.wakeups_per_s=$(plutil -extract wakeupsPerSecond raw -o - "$WORK/shelf-idle.json")"
    --metric "app.shelf.idle.footprint_mb=$(plutil -extract footprintMB raw -o - "$WORK/shelf-idle.json")"
    --metric "a11y.findings=$((A11Y_WALK + A11Y_LINT))"
)

step "edges"
"$EVALS" edges --cli "$CLI" --corpus evals/corpus --cases evals/edges.json --out "$WORK/edges.json"

step "redaction detection"
"$EVALS" detect --corpus evals/corpus >"$WORK/detect.txt"
while IFS= read -r line; do METRICS+=(--metric "$line"); done <"$WORK/detect.txt"

if [ "$QUICK" -eq 0 ]; then
    step "warnings"
    METRICS+=(
        --metric "build.warnings.package=$(warnings_in "$WORK/package-build.log")"
        --metric "build.warnings.app=$(warnings_in "$WORK/app-build.log")"
    )

    step "Debug build warnings"
    # The Release build above hides Debug-only warnings (Swift 6 isolation ones in `#if DEBUG` code); its own folder
    # keeps it from touching the Release products or the user's app.
    xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Debug -derivedDataPath "$EVALS_DEBUG_DERIVED" \
        build >"$WORK/app-debug-build.log" 2>&1 || { tail -30 "$WORK/app-debug-build.log"; exit 1; }
    METRICS+=(--metric "build.warnings.app_debug=$(warnings_in "$WORK/app-debug-build.log")")

    step "code health (audit)"
    # Compared with the baseline like any metric (a count must not grow), with budgets. --clean: a deleted file's old
    # index would otherwise still count.
    EVALS="$EVALS" evals/audit.sh --clean --out "$WORK/audit.json" --report "${RESULTS%.json}-audit.txt"
    AUDIT_ARGS=(--audit "$WORK/audit.json")

    step "package tests"
    swift test --scratch-path "$BUILD" 2>&1 | tee "$WORK/package-tests.log" | tail -3
    read -r COUNT SECONDS_TAKEN <<<"$(test_summary "$WORK/package-tests.log")"
    METRICS+=(--metric "tests.package.count=$COUNT" --metric "tests.package.seconds=$SECONDS_TAKEN")

    step "app tests"
    # Never $BUILD/xcode: the user's own Pomelo runs from there (P90).
    xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Debug \
        -derivedDataPath "$BUILD/xcode-evals-tests" test >"$WORK/app-tests.log" 2>&1 || { tail -40 "$WORK/app-tests.log"; exit 1; }
    tail -3 "$WORK/app-tests.log"
    read -r COUNT SECONDS_TAKEN <<<"$(test_summary "$WORK/app-tests.log")"
    METRICS+=(--metric "tests.app.count=$COUNT" --metric "tests.app.seconds=$SECONDS_TAKEN")
fi

step "results"
MODE=full
[ "$QUICK" -eq 1 ] && MODE=quick
"$EVALS" results --mode "$MODE" --out "$RESULTS" --edges "$WORK/edges.json" --wheel-hook "$HOOK" --custom-wheel-hook "$WORK/hook-custom.json" ${SIGNPOST_ARGS[@]+"${SIGNPOST_ARGS[@]}"} \
    --idle "$WORK/idle.json" --bundle "$WORK/bundle.json" --launch-samples "$WORK/launch-samples.txt" \
    ${AUDIT_ARGS[@]+"${AUDIT_ARGS[@]}"} "${METRICS[@]}"
echo "$RESULTS"

step "compare"
COMPARE=(compare --results "$RESULTS" --baseline evals/baseline.json)
[ "$UPDATE" -eq 1 ] && COMPARE+=(--update-baseline)
"$EVALS" "${COMPARE[@]}"
