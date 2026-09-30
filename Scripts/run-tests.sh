#!/bin/bash
#
# Runs every Swift package's tests, then the app suite in groups, one at a time.
#
# One `xcodebuild test` over 95 test classes is a single process holding a real
# window server session for twenty minutes, and the tests that wait on a window,
# an animation or a panel are the ones that give up when the Mac is busy. Groups
# keep each run short and tear the test host down in between, so a slow machine
# stays a slow machine rather than a failing one.
#
# Nothing here runs in parallel, deliberately — two `xcodebuild test`
# invocations at once fight over the same UI session, and the failures that
# produces ("expected non-nil value of type NSOpenPanel") look like real bugs.
#
#     Scripts/run-tests.sh                 # every package, then every group
#     Scripts/run-tests.sh -g 20           # bigger groups, fewer launches
#     Scripts/run-tests.sh -o Library      # only the classes whose name matches
#     Scripts/run-tests.sh --group 6       # only group 6, as a full run cuts it
#     Scripts/run-tests.sh --no-packages   # skip the packages, run the app only
#
# The packages are found by looking for a `Package.swift` beside this project or
# one level under it — `Packages/<name>` and `Modules/<name>`, which is where
# every one of them lives — so a new package is picked up without an edit here.
#
# Groups are cut from the class names as they are found, so a new test file
# needs no edit here. `--group` counts them the same way, so the number a run
# prints is the one to pass back — with the same `-g`, and without `-o`, which
# would cut different groups. It skips the packages, as `-o` does.
set -u

cd "$(dirname "$0")/.." || exit 1

size=12
only=""
only_group=""
packages=yes

while [ $# -gt 0 ]; do
    case "$1" in
        -g) size="$2"; shift 2 ;;
        -o) only="$2"; shift 2 ;;
        --group) only_group="$2"; shift 2 ;;
        --no-packages|--no-core) packages=no; shift ;;
        -h|--help) sed -n '3,28p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# $DUMPCOMPARE_DD is the name this variable had before the rename; a shell
# that still exports it keeps working.
derived="${BYTERIPPER_DD:-${DUMPCOMPARE_DD:-$PWD/.build/xcode}}"
failed=0

report() {   # keeps the counts, the failures, and any death of the test host
    # A test host that dies mid-run is not a line in this output: XCTest prints
    # "Restarting after unexpected exit", launches a second host, and reports
    # totals that add the two together — so a class whose host crashed can
    # still print "Executed 15 tests, with 0 failures". That is worth a line of
    # its own, at the end, next to the counts it silently qualified.
    awk '
        /^\/Users.*error:|Executed [0-9]+ tests|Restarting after unexpected exit|Program crashed|TEST (FAILED|SUCCEEDED)/ { print; if ($0 ~ /Restarting after unexpected exit|Program crashed/) died = 1 }
        END { if (died) print "  ⚠️  the test host died and XCTest restarted it — these counts span more than one launch" }
    ' | tail -21
}

# The app suite runs sandboxed under its own bundle id, so its `UserDefaults`
# never reach the developer's real preferences. The *package* tests run via
# `swift test`, which is not sandboxed: `cfprefsd` persists their `UserDefaults`
# suites into the developer's own `~/Library/Preferences/`. No environment
# override steers that (measured: `NSHomeDirectory()` and `cfprefsd` both ignore
# `$HOME`), and a cleanup inside the test is undone the moment the test process
# exits — `cfprefsd` re-flushes a domain on client death, after every `tearDown`
# has run (measured with the full `CFPreferences` removal API: the file is gone
# in-process and back by the time the process dies). The only deletion that
# sticks is this one, from here, once the process is gone. Only the exact suites
# the package tests are known to create are removed — never a broad glob.
sweep_package_test_prefs() {
    local dir="$HOME/Library/Preferences"
    [ -d "$dir" ] || return 0
    # `TextDecodingTests-<uuid>.plist`: one per `TextDecoderTests` case, a fresh
    # UUID suite each. `ToolRowMarksTests.plist`: its fixed suite. Nothing else a
    # package test writes lands here.
    rm -f "$dir"/TextDecodingTests-*.plist "$dir"/ToolRowMarksTests.plist 2>/dev/null
    return 0
}

case "$only_group" in
    ''|*[!0-9]*) [ -n "$only_group" ] && { echo "--group takes a number: $only_group" >&2; exit 2; } ;;
esac

if [ "$packages" = yes ] && [ -z "$only" ] && [ -z "$only_group" ]; then
    for package in $(ls -d ./*/Package.swift ./*/*/Package.swift 2>/dev/null \
                     | sed 's|/Package.swift$||' | sort); do
        echo "── ${package#./}"
        ( cd "$package" && swift test 2>&1 ) | report | tail -1
        [ "${PIPESTATUS[0]:-0}" -ne 0 ] && failed=1
        sweep_package_test_prefs
    done
fi

classes=$(grep -h "^final class .*: XCTestCase" ByteRipperTests/*.swift \
    | sed 's/final class \([A-Za-z0-9_]*\).*/\1/' | sort)
if [ -n "$only" ]; then
    classes=$(echo "$classes" | grep -E -- "$only")
fi
[ -z "$classes" ] && { echo "no test classes matched"; exit 1; }

total=$(echo "$classes" | wc -l | tr -d ' ')
group=1
ran=0
index=0
args=""
first=""
last=""

# On macOS 15 a test host can hang in the kernel's exit instead of dying: `ps`
# shows it as `(ByteRipper)` in state `?E` under launchd, `kill -9` does not
# reach it, and only a reboot clears it. xcodebuild waits for it forever, so a
# run that meets one never ends. This lists the hosts in that state, so a group
# can tell a new one from those left by earlier runs.
wedged_hosts() {
    ps -Ao pid=,ppid=,stat=,command= \
        | awk '$2 == 1 && $3 ~ /E/ && $4 == "(ByteRipper)" { print $1 }' | sort
}

# How long a host may sit in its exit before the group is given up on. A host
# that is dying passes through that state in well under a second.
wedge_grace=30

run_group() {
    [ -z "$args" ] && return
    if [ -n "$only_group" ] && [ "$group" -ne "$only_group" ]; then
        group=$((group + 1)) args="" first=""
        return
    fi
    ran=$((ran + 1))
    echo "── group $group: $first … $last"
    local before pidfile statusfile runner xcpid wedged since=0
    before=$(wedged_hosts)
    pidfile=$(mktemp) statusfile=$(mktemp)
    # The test host under its own bundle identifier: its sandbox container and
    # preferences domain are its own, so a run leaves nothing in the user's
    # real settings — including the autosaves AppKit writes on the host's
    # behalf (a window frame, a panel's size), which take no app-level seam.
    # The scheme cannot carry this (XcodeGen drops test-action build settings),
    # so the runner is the one place that must say it; a hand-run xcodebuild
    # that forgets is refused by the AppDefaults guard rather than left to
    # write the user's settings.
    # xcodebuild runs in the background so the group can be watched: a host
    # that hangs in its exit is not waited on, the group is stopped and said
    # to have failed, and the run goes on to the next one.
    (
        # shellcheck disable=SC2086
        xcodebuild -project ByteRipper.xcodeproj -scheme ByteRipper \
            -derivedDataPath "$derived" -parallel-testing-enabled NO \
            BYTERIPPER_APP_BUNDLE_ID=dev.maxik.ByteRipper.TestsHost \
            $args test 2>&1 &
        echo $! > "$pidfile"
        wait $!
        echo $? > "$statusfile"
    ) 2>/dev/null | report &   # 2>: the shell's own "Terminated" when a group is stopped
    runner=$!
    while kill -0 "$runner" 2>/dev/null; do
        sleep 2
        wedged=$(comm -13 <(echo "$before") <(wedged_hosts) | tr '\n' ' ')
        if [ -z "${wedged// /}" ]; then since=0; continue; fi
        since=$((since + 2))
        [ "$since" -lt "$wedge_grace" ] && continue
        xcpid=$(cat "$pidfile" 2>/dev/null)
        [ -n "$xcpid" ] && kill "$xcpid" 2>/dev/null
        wait "$runner" 2>/dev/null
        echo "  ⚠️  the test host hung in its exit (pid ${wedged% }) — group stopped; only a reboot clears it"
        echo 1 > "$statusfile"
        break
    done
    wait "$runner" 2>/dev/null
    status=$(cat "$statusfile" 2>/dev/null)
    rm -f "$pidfile" "$statusfile"
    [ "${status:-1}" -ne 0 ] && failed=1
    group=$((group + 1))
    args=""
    first=""
}

for class in $classes; do
    args="$args -only-testing:ByteRipperTests/$class"
    [ -z "$first" ] && first="$class"
    last="$class"
    index=$((index + 1))
    if [ $((index % size)) -eq 0 ]; then
        run_group
    fi
done
run_group

if [ -n "$only_group" ]; then
    [ "$ran" -eq 0 ] && { echo "no group $only_group: $total classes make $((group - 1)) group(s) of $size"; exit 1; }
    echo "── group $only_group of $((group - 1))"
else
    echo "── $total classes in $((group - 1)) group(s)"
fi
[ "$failed" -ne 0 ] && { echo "── something failed"; exit 1; }
echo "── all green"
