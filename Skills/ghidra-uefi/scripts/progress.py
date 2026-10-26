"""Saying what a long step is doing while it does it.

The skill's slow steps — a Ghidra run, the EDK2 clone, a download — take
seconds to minutes, and their own output goes to a log or nowhere. Without a
word on the terminal they look like a hang. Each step here says what it is
when it starts, how long it has run while it runs, and how long it took; and
each has a time limit, so a stalled network ends with a message instead of
never.

On a terminal the running line rewrites itself once a second. Anywhere else —
an agent reading the output, a CI log — a line every fifteen seconds is enough
and does not flood the log.

Stdlib only.
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path


def say(text: str) -> None:
    print(text, file=sys.stderr, flush=True)


class Step:
    """`with Step("Analyzing CpuPei in Ghidra"): …` — the start, a heartbeat
    via `tick()`, and the time it took."""

    def __init__(self, label: str):
        self.label = label
        self.start = time.monotonic()
        # The first heartbeat comes a beat after the start line, not with it.
        self.last = self.start
        self.live = sys.stderr.isatty()

    def __enter__(self) -> "Step":
        say(f"{self.label} …")
        return self

    def elapsed(self) -> int:
        return int(time.monotonic() - self.start)

    def tick(self, detail: str = "") -> None:
        now = time.monotonic()
        if self.live:
            if now - self.last >= 1:
                self.last = now
                extra = f", {detail}" if detail else ""
                print(f"\r  {self.elapsed()} s{extra}   ", end="", file=sys.stderr, flush=True)
        elif now - self.last >= 15:
            self.last = now
            extra = f", {detail}" if detail else ""
            say(f"  still {self.label[0].lower() + self.label[1:]}: {self.elapsed()} s{extra}")

    def __exit__(self, kind, error, trace) -> None:
        if self.live:
            print("\r", end="", file=sys.stderr)
        say(f"{self.label}: {'done' if kind is None else 'stopped'} in {self.elapsed()} s")


def run(command: list[str], label: str, log: Path | None = None,
        timeout: float = 1800) -> int:
    """Runs a program with a heartbeat. Its output goes to `log` when one is
    given, and to the terminal otherwise (git prints its own progress). Past
    `timeout` seconds the program is stopped and the step fails with a
    sentence that says so."""
    with Step(label) as step:
        handle = open(log, "w", encoding="utf-8") if log else None
        try:
            process = subprocess.Popen(command, stdout=handle or None,
                                       stderr=subprocess.STDOUT if handle else None)
            while process.poll() is None:
                if step.elapsed() > timeout:
                    process.kill()
                    process.wait()
                    where = f"; log: {log}" if log else ""
                    raise SystemExit(f"{label}: stopped after {int(timeout)} s with no result{where}")
                # A program writing to the terminal (git's own progress) is not
                # talked over; the heartbeat is for one whose output is logged.
                if log or not step.live:
                    step.tick()
                time.sleep(0.2)
            return process.returncode
        finally:
            if handle:
                handle.close()
