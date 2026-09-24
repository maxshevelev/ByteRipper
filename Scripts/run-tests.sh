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
#     Scripts/run-tests.sh --no-packages   # skip the packages, run the app only
#
# The packages are found by looking for a `Package.swift` beside this project or
# one level under it — `Packages/<name>` and `Modules/<name>`, which is where
# every one of them lives — so a new package is picked up without an edit here.
#
# Groups are cut from the class names as they are found, so a new test file
# needs no edit here.
set -u

cd "$(dirname "$0")/.." || exit 1

size=12
only=""
packages=yes

while [ $# -gt 0 ]; do
    case "$1" in
        -g) size="$2"; shift 2 ;;
        -o) only="$2"; shift 2 ;;
        --no-packages|--no-core) packages=no; shift ;;
        -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
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

if [ "$packages" = yes ] && [ -z "$only" ]; then
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
index=0
args=""
first=""
last=""

run_group() {
    [ -z "$args" ] && return
    echo "── group $group: $first … $last"
    # The test host under its own bundle identifier: its sandbox container and
    # preferences domain are its own, so a run leaves nothing in the user's
    # real settings — including the autosaves AppKit writes on the host's
    # behalf (a window frame, a panel's size), which take no app-level seam.
    # The scheme cannot carry this (XcodeGen drops test-action build settings),
    # so the runner is the one place that must say it; a hand-run xcodebuild
    # that forgets is refused by the AppDefaults guard rather than left to
    # write the user's settings.
    # shellcheck disable=SC2086
    xcodebuild -project ByteRipper.xcodeproj -scheme ByteRipper \
        -derivedDataPath "$derived" -parallel-testing-enabled NO \
        BYTERIPPER_APP_BUNDLE_ID=dev.maxik.ByteRipper.TestsHost \
        $args test 2>&1 | report
    status=${PIPESTATUS[0]}
    [ "$status" -ne 0 ] && failed=1
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

echo "── $total classes in $((group - 1)) group(s)"
[ "$failed" -ne 0 ] && { echo "── something failed"; exit 1; }
echo "── all green"
