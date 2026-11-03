#!/bin/bash
# Pomelo's code-health audit (Phase 6): dead code (Periphery), duplication (jscpd), complexity (lizard) and the
# comment counts, as metrics for evals/run.sh and a findings list for whoever debloats.
# Usage: evals/audit.sh [--clean] [--out <results.json>] [--report <findings.txt>]
#   --clean   rebuild the Periphery index stores from scratch (a deleted file's old index would still be read)
# It installs nothing. A missing tool prints how to install it and its metrics come out "skipped".
# Exit 0 when the audit ran (tools missing or not), 1 when a build or the audit itself failed, 2 on a usage error.
set -euo pipefail

CLEAN=0
OUT=""
REPORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1 ;;
        --out) OUT="${2:?--out needs a path}"; shift ;;
        --report) REPORT="${2:?--report needs a path}"; shift ;;
        *) echo "usage: evals/audit.sh [--clean] [--out <results.json>] [--report <findings.txt>]" >&2; exit 2 ;;
    esac
    shift
done

cd "$(dirname "$0")/.."
BUILD="$HOME/Library/Caches/Pomelo-build"
PERIPHERY_PACKAGE="$BUILD/periphery-package"
PERIPHERY_APP="$BUILD/periphery-app"
VENV="$BUILD/tools/venv"
JSCPD_VERSION="5.4.2"
LIZARD_VERSION="1.24.3"
STAMP="$(date +%Y-%m-%d-%H%M)"
mkdir -p evals/results
OUT="${OUT:-evals/results/audit-$STAMP.json}"
REPORT="${REPORT:-evals/results/audit-$STAMP.txt}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pomelo-audit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

step() { echo "==> $*"; }
SOURCES=(Sources App/Sources App/QuickAction)
ARGS=()
for directory in "${SOURCES[@]}"; do ARGS+=(--sources "$directory"); done

# run.sh hands over the binary it just built; alone, an old build would not know the audit command.
if [ -z "${EVALS:-}" ]; then
    EVALS="$BUILD/evals/release/pomelo-evals"
    step "build pomelo-evals (release)"
    swift build -c release --product pomelo-evals --scratch-path "$BUILD/evals" 2>&1 | tail -3
fi

# Periphery -----------------------------------------------------------------------------------------------------
if command -v periphery >/dev/null 2>&1; then
    if [ "$CLEAN" -eq 1 ]; then rm -rf "$PERIPHERY_PACKAGE" "$PERIPHERY_APP"; fi
    step "index the package (tests included)"
    swift build --build-tests --scratch-path "$PERIPHERY_PACKAGE" 2>&1 | tail -2
    step "index the app (DEBUG and POMELO_EVALS, tests included)"
    xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Debug -derivedDataPath "$PERIPHERY_APP" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) POMELO_EVALS' build-for-testing >"$WORK/periphery-app-build.log" 2>&1 \
        || { tail -30 "$WORK/periphery-app-build.log"; exit 1; }
    # SwiftPM's index store is wherever its build system puts the "v5" folder; Xcode's is fixed.
    V5="$(find "$PERIPHERY_PACKAGE" -maxdepth 4 -type d -name v5 -print -quit)"
    # dirname "" is ".", which Periphery would index as the repository.
    [ -n "$V5" ] || { echo "no SwiftPM index store (a v5 folder) under $PERIPHERY_PACKAGE; run with --clean" >&2; exit 1; }
    PACKAGE_STORE="$(dirname "$V5")"
    APP_STORE="$PERIPHERY_APP/Index.noindex/DataStore"
    TEST_TARGETS='"PomeloCoreTests","PomeloEnginesTests","PomeloUIModelTests","PomeloCLIKitTests","PomeloEvalsKitTests","PomeloAppTests"'
    for variant in tests no-tests; do
        TARGETS="[]"
        [ "$variant" = "no-tests" ] && TARGETS="[$TEST_TARGETS]"
        cat >"$WORK/periphery-$variant.json" <<EOF
{
  "indexstores": ["$PACKAGE_STORE", "$APP_STORE"],
  "plists": ["$PWD/App/Info.plist", "$PWD/App/QuickAction/Info.plist"],
  "xibs": [], "xcmappingmodels": [], "xcdatamodels": [],
  "test_targets": $TARGETS
}
EOF
    done
    step "periphery"
    periphery scan --generic-project-config "$WORK/periphery-tests.json" --skip-build --format json --quiet \
        --disable-update-check --write-results "$WORK/periphery.json" >"$WORK/periphery.log" 2>&1 \
        || { tail -20 "$WORK/periphery.log"; exit 1; }
    periphery scan --generic-project-config "$WORK/periphery-no-tests.json" --exclude-tests --skip-build --format json --quiet \
        --disable-update-check --write-results "$WORK/periphery-no-tests.json" >"$WORK/periphery-no-tests.log" 2>&1 \
        || { tail -20 "$WORK/periphery-no-tests.log"; exit 1; }
    ARGS+=(--periphery "$WORK/periphery.json" --periphery-without-tests "$WORK/periphery-no-tests.json")
else
    echo "periphery is not installed, so the dead-code metrics are skipped. Install it with: brew install periphery" >&2
fi

# jscpd ---------------------------------------------------------------------------------------------------------
if command -v npx >/dev/null 2>&1; then
    step "jscpd $JSCPD_VERSION"
    if npx --yes "jscpd@$JSCPD_VERSION" --config .jscpd.json --absolute --output "$WORK/jscpd" >"$WORK/jscpd.log" 2>&1 \
        && [ -f "$WORK/jscpd/jscpd-report.json" ]; then
        ARGS+=(--jscpd "$WORK/jscpd/jscpd-report.json")
    else
        tail -10 "$WORK/jscpd.log" >&2
        echo "jscpd $JSCPD_VERSION did not run (offline?), so the duplication metric is skipped" >&2
    fi
else
    echo "npx is not installed, so the duplication metric is skipped. Install Node with: brew install node" >&2
fi

# lizard --------------------------------------------------------------------------------------------------------
LIZARD="$VENV/bin/lizard"
if [ -x "$LIZARD" ]; then
    step "lizard"
    "$LIZARD" -l swift --csv "${SOURCES[@]}" >"$WORK/lizard.csv"
    ARGS+=(--lizard "$WORK/lizard.csv")
else
    # Homebrew's "lizard" is a different program (a compressor): the analyzer comes from PyPI.
    echo "lizard is not installed, so the complexity metrics are skipped. Install it with:" >&2
    echo "  python3 -m venv $VENV && $VENV/bin/pip install lizard==$LIZARD_VERSION" >&2
fi

step "audit"
"$EVALS" audit "${ARGS[@]}" --out "$OUT" --report "$REPORT"
echo "metrics: $OUT"
echo "findings: $REPORT"
