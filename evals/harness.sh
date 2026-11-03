# Helpers for evals/run.sh, sourced (not executed) so evals/harness-selftest.sh can exercise them on stand-ins.

# Every PID below $1, deepest first, so a parent is never killed before the children it would reap.
descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null || true); do
        descendants "$child"
        echo "$child"
    done
}

# run_with_deadline <seconds> <command...>: the command's own status, or 124 after <seconds>. On the deadline the
# command and its descendants are killed by exact PID (TERM, then KILL after a grace second): xctrace has hung past
# its own --time-limit. An app that xctrace asked Launch Services to start is not its descendant; run.sh's
# reap_measured_app finds that one by its arguments. While it waits it notes the instruments*.ktrace files the
# command's process tree holds open in $KTRACE_CLAIMS (see claim_ktraces).
run_with_deadline() {
    local seconds="$1"
    shift
    "$@" &
    local pid=$! ticks=0 victim
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((seconds * 10)) ]; then
            local victims
            victims="$(descendants "$pid") $pid"
            for victim in $victims; do kill -TERM "$victim" 2>/dev/null || true; done
            sleep 1
            for victim in $victims; do kill -KILL "$victim" 2>/dev/null || true; done
            { wait "$pid"; } 2>/dev/null || true
            return 124
        fi
        claim_ktraces "$pid"
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

# started_under_pattern <work folder>: an extended regex for the command line `<program> --eval-<hook> ... <folder>/...`.
# The folder is this run's mktemp one, so only processes this run started can match, whichever copy of the app they
# run from (xctrace resolves the app by name and may launch another one). The program is a path that may hold spaces
# but never " -": xctrace's own line ("xctrace record --time-limit ... --launch -- <app> --eval-...") repeats the
# hook text later on, and must not match. The folder ends in "/" so work.AbC1 does not match work.AbC12/.
started_under_pattern() {
    local folder
    folder="$(printf '%s' "$1" | sed 's/[][\\.*^$(){}+?|]/\\&/g')"
    printf '%s' "^/([^ ]| [^- ])* --eval-[a-z-]+ .*$folder/"
}

# reap_started_under <work folder>: kills what started_under_pattern matches.
reap_started_under() {
    pkill -KILL -f "$(started_under_pattern "$1")" 2>/dev/null || true
}

# traced_app_path <toc.xml>: the path xctrace recorded for the process it launched (`xctrace export --toc`).
traced_app_path() {
    xmllint --xpath 'string(//run[@number="1"]/processes/process[@pid=//run[@number="1"]/info/target/process/@pid]/@path)' "$1" 2>/dev/null
}

# same_location <a> <b>: both exist and are one and the same place once symlinks are resolved.
same_location() {
    [ -e "$1" ] && [ -e "$2" ] && [ "$(cd "$1" && pwd -P)" = "$(cd "$2" && pwd -P)" ]
}

# claim_ktraces <pid>: adds to $KTRACE_CLAIMS (when set) the instruments*.ktrace files that <pid> or its descendants
# hold open right now. xctrace writes one per recording, in the user temp folder whatever TMPDIR says, and keeps it open
# only while recording, so run_with_deadline asks every tick. A file seen open by this run's own process tree is this
# run's; nothing else is ever claimed, and lsof reports real paths, so no temp folder has to be guessed.
claim_ktraces() {
    [ -n "${KTRACE_CLAIMS:-}" ] || return 0
    local pids
    pids="$({ descendants "$1"; echo "$1"; } | paste -sd, -)"
    lsof -nP -Fn -p "$pids" 2>/dev/null | sed -n 's/^n\(.*\/instruments[^/]*\.ktrace\)$/\1/p' >>"$KTRACE_CLAIMS" || true
}

# remove_claimed_ktraces: deletes the claimed files that no process holds open any more, then forgets the claims, so
# calling it again (the exit trap) only has work to do if the step was interrupted.
remove_claimed_ktraces() {
    [ -s "${KTRACE_CLAIMS:-}" ] || return 0
    local file
    while IFS= read -r file; do
        if [ -e "$file" ] && [ -z "$(lsof -t -- "$file" 2>/dev/null)" ]; then rm -f -- "$file"; fi
    done < <(sort -u "$KTRACE_CLAIMS")
    : >"$KTRACE_CLAIMS"
    return 0
}

# warnings_in <build log>: the unique warnings in it. Compiler warnings count once per file, line and text, however many
# architectures built them; a warning without a source location counts too, except the one note the release CLI's
# link-time strip makes dsymutil print ("no debug symbols in executable", P148, P153): that build is stripped on
# purpose, and keeping `swift build -c release` as the shipped build matters more than silencing it with
# `-debug-info-format none` (which also grew the CLI by 16 KB).
warnings_in() {
    {
        grep -E '^/.*: warning:' "$1" | sort -u
        grep -E '^warning:' "$1" | grep -vE '^warning: no debug symbols in executable( \(-arch [A-Za-z0-9_]+\))?$' | sort -u
    } | wc -l | tr -d ' ' || true
}
