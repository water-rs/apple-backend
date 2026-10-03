#!/usr/bin/env python3
"""Wait for a packaged WaterUI app's first-paint marker on an iOS simulator.

Readiness is the app's own signal, not a returned pid. This helper attaches
`log stream --style ndjson` inside the booted simulator and waits for the
stream's `Filtering the log data` attach header BEFORE launching — a marker
can never be lost to an attach race — then launches the app with
`--terminate-running-process` and accepts `waterui_first_paint_ms=` only
when the event's processID is the pid of this launch. A marker emitted by
an older run of the same bundle id, or by any other process on the
subsystem, is rejected. Because nothing is consumed while the launch is in
flight, no event is read before the pid is known; there is no poll, no
sleep, and no replay of the persisted log store — an old run's marker can
never satisfy this launch.

The whole path is bounded by one asyncio.wait_for deadline (30 s). Stream
loss, a failed launch, a process that exits before painting, or a deadline
expiry all fail nonzero. On every path — success, failure, interruption —
the owned log-stream child is killed and the app is terminated.

usage: wait-native-first-paint.py <simulator-udid> <bundle-id>
stdout: `first paint: <ms> ms`; diagnostics on stderr.
"""

import asyncio
import json
import re
import sys

SUBSYSTEM = "dev.waterui"
MARKER = re.compile(r"waterui_first_paint_ms=(\d+)\b")
ATTACH_PREFIX = "Filtering the log data"
LAUNCH_PID = re.compile(r":\s*(\d+)\s*$")
DEADLINE_S = 30.0


class Failure(Exception):
    """Any path on which this launch never proved it reached first paint."""


def _marker_ms(event, pid):
    """Marker value when `event` is the first-paint log from process `pid`."""
    if not isinstance(event, dict):
        raise Failure("log stream event is not a JSON object")
    if event.get("processID") != pid or event.get("subsystem") != SUBSYSTEM:
        return None
    match = MARKER.search(event.get("eventMessage") or "")
    return int(match.group(1)) if match else None


async def _lines(stdout):
    while True:
        raw = await stdout.readline()
        if not raw:
            raise Failure("log stream closed before the first-paint marker")
        yield raw.decode("utf-8", errors="replace").rstrip("\n")


async def _await_attach(lines):
    async for line in lines:
        if line.startswith(ATTACH_PREFIX):
            return
        raise Failure(f"unexpected log stream output before attach: {line!r}")


async def _await_marker(lines, pid):
    async for line in lines:
        if line.startswith(ATTACH_PREFIX):
            continue
        try:
            event = json.loads(line)
        except ValueError as exc:
            raise Failure(f"unexpected log stream output: {line!r}") from exc
        ms = _marker_ms(event, pid)
        if ms is not None:
            return ms
    raise Failure("log stream ended before the first-paint marker")


async def _run(udid, bundle_id):
    stream = await asyncio.create_subprocess_exec(
        "xcrun", "simctl", "spawn", udid, "log", "stream",
        "--level", "info",
        "--predicate", f'subsystem == "{SUBSYSTEM}"',
        "--style", "ndjson",
        stdout=asyncio.subprocess.PIPE,
    )
    launch_proc = None
    try:
        lines = _lines(stream.stdout)
        await _await_attach(lines)
        launch_proc = await asyncio.create_subprocess_exec(
            "xcrun", "simctl", "launch", "--terminate-running-process",
            udid, bundle_id,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        out, _ = await launch_proc.communicate()
        text = out.decode("utf-8", errors="replace").strip()
        if launch_proc.returncode != 0:
            raise Failure(f"simctl launch {bundle_id} failed: {text}")
        match = LAUNCH_PID.search(text)
        if not match:
            raise Failure(f"simctl launch reported no pid: {text!r}")
        ms = await _await_marker(lines, int(match.group(1)))
        print(f"first paint: {ms} ms")
    finally:
        if stream.returncode is None:
            stream.kill()
        await stream.wait()
        # Once the launch child exists the bundle may have started
        # sim-side, even if reading the launch output was cancelled — so
        # cleanup is keyed on the attempt, not on a parsed pid. A still
        # running launch child is killed and awaited first.
        if launch_proc is not None:
            if launch_proc.returncode is None:
                launch_proc.kill()
                await launch_proc.wait()
            terminate = await asyncio.create_subprocess_exec(
                "xcrun", "simctl", "terminate", udid, bundle_id,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await terminate.wait()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    udid, bundle_id = sys.argv[1], sys.argv[2]
    try:
        asyncio.run(asyncio.wait_for(_run(udid, bundle_id), DEADLINE_S))
    except Failure as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    except TimeoutError:
        print(f"error: no first-paint marker from {bundle_id} within "
              f"{DEADLINE_S:.0f}s", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
