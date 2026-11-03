#!/bin/bash
# Checks evals/harness.sh's helpers, and the wheel step of evals/run.sh, on stand-in processes and a fake xcrun (nothing
# of Pomelo or Instruments runs). Usage: evals/harness-selftest.sh
# Exit 0: all passed. Exit 1: a check failed.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
. evals/harness.sh

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pomelo-harness-selftest.XXXXXX")"
PIDS=()
cleanup() {
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill -KILL "$pid" 2>/dev/null || true; { wait "$pid"; } 2>/dev/null || true; done
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
FAILED=0
check() { # check <name> <command...>: passes when the command succeeds
    local name="$1"
    shift
    if "$@"; then echo "ok     $name"; else echo "FAILED $name"; FAILED=1; fi
}
alive() { kill -0 "$1" 2>/dev/null; }
gone() { ! kill -0 "$1" 2>/dev/null; }
matches() { pgrep -f "$(started_under_pattern "$1")" | grep -qx "$2"; } # matches <work folder> <pid>
not_matches() { ! matches "$@"; }

# run_with_deadline -----------------------------------------------------------------------------------------------
run_with_deadline 5 sh -c 'exit 3'
check "the command's own status comes back" [ $? -eq 3 ]
run_with_deadline 5 true
check "success comes back as 0" [ $? -eq 0 ]
started=$SECONDS
run_with_deadline 1 sh -c 'sleep 60 & echo $! >"$0"; sleep 60' "$SCRATCH/child.pid"
status=$?
check "a hang is cut off with status 124 after the deadline" [ "$status" -eq 124 ]
check "and takes about the deadline plus the grace second" [ $((SECONDS - started)) -le 6 ]
child="$(cat "$SCRATCH/child.pid" 2>/dev/null || echo 0)"
check "and what the command started is gone too" gone "$child"

# started_under_pattern / reap_started_under ----------------------------------------------------------------------
mkdir -p "$SCRATCH/other-copy" "$SCRATCH/with space" "$SCRATCH/work.one" "$SCRATCH/work.two" "$SCRATCH/work.123" \
    "$SCRATCH/work.1234" "$SCRATCH/xctrace-dir"
cat >"$SCRATCH/stand-in.c" <<'C'
#include <unistd.h>
int main(void) { sleep(120); return 0; }
C
clang -o "$SCRATCH/other-copy/PomeloEvals" "$SCRATCH/stand-in.c" 2>/dev/null
cp "$SCRATCH/other-copy/PomeloEvals" "$SCRATCH/with space/PomeloEvals"
cp "$SCRATCH/other-copy/PomeloEvals" "$SCRATCH/xctrace-dir/xctrace"
"$SCRATCH/other-copy/PomeloEvals" --eval-launch "$SCRATCH/work.one/launch.json" & mine=$!
"$SCRATCH/other-copy/PomeloEvals" --eval-launch "$SCRATCH/work.two/launch.json" & theirs=$!
"$SCRATCH/with space/PomeloEvals" --eval-idle 30 "$SCRATCH/work.123/idle.json" & spaced=$!
"$SCRATCH/other-copy/PomeloEvals" --eval-idle 30 "$SCRATCH/work.1234/idle.json" & longer=$!
# What xctrace's own command line looks like: the hook text comes after "--launch --".
"$SCRATCH/xctrace-dir/xctrace" record --template Logging --time-limit 60s --output "$SCRATCH/work.one/wheel.trace" \
    --launch -- "$SCRATCH/other-copy/PomeloEvals" --eval-wheel-open "$SCRATCH/work.one/photo.png" 200 "$SCRATCH/work.one/hook.json" & tracer=$!
PIDS+=("$mine" "$theirs" "$spaced" "$longer" "$tracer")
sleep 0.5
check "the pattern matches a process of the run started from another copy of the app" matches "$SCRATCH/work.one" "$mine"
check "a path with a space in it matches" matches "$SCRATCH/work.123" "$spaced"
check "another run's process does not" not_matches "$SCRATCH/work.one" "$theirs"
check "a folder that only starts like the run's does not (work.123 against work.1234/)" not_matches "$SCRATCH/work.123" "$longer"
check "an xctrace-shaped command line does not, though it holds the same --eval- text" not_matches "$SCRATCH/work.one" "$tracer"
reap_started_under "$SCRATCH/work.one"
{ wait "$mine"; } 2>/dev/null
check "reaping kills the run's process" gone "$mine"
check "and leaves another run's, the longer folder's, the spaced one and the xctrace-shaped one alone" \
    bash -c "kill -0 $theirs && kill -0 $longer && kill -0 $spaced && kill -0 $tracer"

# traced_app_path and same_location -------------------------------------------------------------------------------
cat >"$SCRATCH/toc.xml" <<XML
<?xml version="1.0"?>
<trace-toc><run number="1"><info><target>
<process arguments="--eval-launch x" type="launched" return-exit-status="0" name="PomeloEvals" pid="17271" termination-reason="exit(0)"/>
</target></info><processes>
<process name="kernel" pid="0" path="/System/Library/Kernels/kernel.release.t8142"/>
<process name="PomeloEvals" pid="17271" path="$SCRATCH/other-copy"/>
</processes></run></trace-toc>
XML
check "the recorded process path is read from the trace's table of contents" \
    [ "$(traced_app_path "$SCRATCH/toc.xml")" = "$SCRATCH/other-copy" ]
ln -s "$SCRATCH/other-copy" "$SCRATCH/link"
check "a symlink to the same folder is the same location" same_location "$SCRATCH/link" "$SCRATCH/other-copy"
check "another folder is not" bash -c ". evals/harness.sh; ! same_location '$SCRATCH/work.one' '$SCRATCH/other-copy'"
check "a missing path is not" bash -c ". evals/harness.sh; ! same_location '$SCRATCH/missing' '$SCRATCH/missing'"

# claim_ktraces and remove_claimed_ktraces ------------------------------------------------------------------------
KT="$SCRATCH/ktraces"
mkdir -p "$KT"
export KTRACE_CLAIMS="$KT/claims"
: >"$KTRACE_CLAIMS"
: >"$KT/instrumentsOLDCLOSED.ktrace" # someone else's finished recording, new or old: never claimed
sh -c 'exec 3>"$0"; exec sleep 120' "$KT/instrumentsFOREIGN.ktrace" & foreign=$! # another session's, held open
PIDS+=("$foreign")
sleep 0.3
# The run's own: a command under run_with_deadline that holds one open for a moment, as xctrace does while recording.
run_with_deadline 10 sh -c 'exec 3>"$0"; sleep 1.5' "$KT/instrumentsOWN.ktrace"
check "a ktrace the run's process tree held open is claimed" grep -q "/instrumentsOWN.ktrace$" "$KTRACE_CLAIMS"
check "another session's open ktrace is not claimed" bash -c "! grep -q FOREIGN '$KTRACE_CLAIMS'"
echo "$KT/instrumentsFOREIGN.ktrace" >>"$KTRACE_CLAIMS" # even claimed by mistake, an open file is left alone
remove_claimed_ktraces
check "the run's own ktrace is removed" [ ! -e "$KT/instrumentsOWN.ktrace" ]
check "another session's, still open, survives" [ -e "$KT/instrumentsFOREIGN.ktrace" ]
check "a closed one nobody claimed survives" [ -e "$KT/instrumentsOLDCLOSED.ktrace" ]
check "the claims are forgotten" [ ! -s "$KTRACE_CLAIMS" ]

# The wheel step of run.sh, with a fake xcrun ---------------------------------------------------------------------
# FAKE_MODE: ok (the trace says the build ran), other (it says another app ran), broken (the table of contents is not
# XML), hang (the recording never ends).
FAKE_APP="$SCRATCH/build/PomeloEvals.app"
mkdir -p "$FAKE_APP/Contents/MacOS"
{
    echo 'set -euo pipefail'
    echo "cd '$REPO'"
    echo '. evals/harness.sh'
    echo "APP='$FAKE_APP'"
    echo 'APP_BINARY="$APP/Contents/MacOS/PomeloEvals"'
    echo "WORK='$SCRATCH/wheel-work'; mkdir -p \"\$WORK\""
    echo 'APP_CORPUS="$WORK"'
    echo 'KTRACE_CLAIMS="$WORK/ktrace-claims"'
    echo 'step() { :; }'
    echo 'reap_measured_app() { reap_started_under "$WORK"; }'
    cat <<'FAKE'
xcrun() {
    local output="" mode="$FAKE_MODE"
    for ((i = 1; i <= $#; i++)); do [ "${!i}" = "--output" ] && output="${@:i+1:1}"; done
    case " $* " in
        *" record "*)
            [ "$mode" = hang ] && exec sleep 300
            for last; do :; done; : >"$last" ;; # the hook file is the last argument
        *" --toc "*)
            if [ "$mode" = broken ]; then echo "not xml" >"$output"; return 0; fi
            local path="$APP"; [ "$mode" = other ] && path="/elsewhere/PomeloEvals.app"
            echo "<trace-toc><run number=\"1\"><info><target><process pid=\"7\"/></target></info><processes><process pid=\"7\" path=\"$path\"/></processes></run></trace-toc>" >"$output" ;;
        *) : >"$output" ;;
    esac
}
FAKE
    echo 'SIGNPOST_ARGS=()'
    sed -n '/^step "wheel open"/,/^step "wheel open (customized)"/p' evals/run.sh | sed '$d'
} >"$SCRATCH/wheel-block.sh"
mkdir -p "$SCRATCH/build/PomeloEvals.app"
run_block() { FAKE_MODE="$1" POMELO_XCTRACE_DEADLINE="${2:-20}" bash "$SCRATCH/wheel-block.sh" 2>"$SCRATCH/block.err"; }
run_block ok
check "the wheel step passes when the trace names the evals build" [ $? -eq 0 ]
run_block other
check "it fails when the trace names another app" [ $? -eq 1 ]
check "and says which app was timed" grep -q "xctrace timed '/elsewhere/PomeloEvals.app', not the evals build" "$SCRATCH/block.err"
run_block broken
check "an unreadable table of contents still ends in the step's own message, not a silent exit" [ $? -eq 1 ]
check "which names an unknown app" grep -q "xctrace timed 'an unknown app'" "$SCRATCH/block.err"
started=$SECONDS
run_block hang 2
status=$?
check "a hung recording fails the step" [ "$status" -eq 1 ]
check "within the deadline plus the grace second" [ $((SECONDS - started)) -le 8 ]
check "with a message" grep -q "xctrace hung: killed after 2 s" "$SCRATCH/block.err"

# warnings_in ------------------------------------------------------------------------------------------------------
cat >"$SCRATCH/build.log" <<'LOG'
/repo/Sources/A.swift:3:5: warning: variable 'x' was never used
/repo/Sources/A.swift:3:5: warning: variable 'x' was never used
/repo/Sources/B.swift:9:1: warning: unused result
warning: no debug symbols in executable (-arch arm64)
Build complete! (16,51 sec)
LOG
check "warnings are counted once per file, line and text; the release CLI's stripped-binary note is not one" \
    [ "$(warnings_in "$SCRATCH/build.log")" = "2" ]
printf 'warning: unable to find a module map\n/repo/C.swift:1:1: warning: x\n' >"$SCRATCH/other.log"
check "any other warning without a source location is counted" [ "$(warnings_in "$SCRATCH/other.log")" = "2" ]
printf 'warning: no debug symbols in executable (-arch arm64) and more\n' >"$SCRATCH/near.log"
check "a line that only starts like the known note is counted" [ "$(warnings_in "$SCRATCH/near.log")" = "1" ]
: >"$SCRATCH/empty.log"
check "a log with none is 0" [ "$(warnings_in "$SCRATCH/empty.log")" = "0" ]

[ "$FAILED" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
