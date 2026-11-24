#!/usr/bin/env python3
"""Check the startup log from a fresh Poki install on a dedicated, booted iOS simulator."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import select
import subprocess
from time import monotonic


def simctl(command, device, *args):
    return subprocess.check_output(
        ["xcrun", "simctl", command, device, *args], text=True, timeout=30
    ).strip()


def watch(directory):
    descriptor = os.open(directory, os.O_RDONLY)
    queue = select.kqueue()
    event = select.kevent(
        descriptor, filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
        fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME,
    )
    queue.control([event], 0, 0)
    return descriptor, queue


def launch(device, bundle):
    return int(simctl("launch", device, bundle).rsplit(": ", 1)[1])


def check(device, app):
    with (app / "Info.plist").open("rb") as stream:
        bundle = plistlib.load(stream)["CFBundleIdentifier"]
    simctl("install", device, str(app))
    container = Path(simctl("get_app_container", device, bundle, "data"))
    support = container / "Library" / "Application Support" / "Poki"
    support.mkdir(parents=True, exist_ok=True)
    log = support / "startup.log"
    assert not log.exists(), "Use a dedicated simulator with a fresh install of Poki"
    descriptor, queue = watch(support)
    try:
        launch(device, bundle)
        deadline = monotonic() + 15
        while not log.exists():
            if not queue.control(None, 1, max(0, deadline - monotonic())):
                raise AssertionError("First launch did not write a startup log for Poki Setup")
        content = log.read_text()
        assert re.search(r"\bfirst_frame_ms=[1-9]\d*\b", content), content
        for view in ("ChatTopBar", "ComposerInputView", "HomeSuggestions", "FirstRunGuide"):
            assert re.search(rf"\b{view}@\d+ms\b", content), content
        assert "first_frame_custom_glass=deferred" in content, content
        initial = log.stat()
        print(f"First launch: {content.strip()}", flush=True)
        simctl("terminate", device, bundle)
        pid = launch(device, bundle)
        # Allow the second process time to draw and persist a report if it incorrectly logs again.
        deadline = monotonic() + 5
        while monotonic() < deadline:
            queue.control(None, 1, max(0, deadline - monotonic()))
            current = log.stat()
            assert (current.st_ino, current.st_mtime_ns) == (initial.st_ino, initial.st_mtime_ns), (
                "A second launch of the same build rewrote the startup log"
            )
        listing = simctl("spawn", device, "launchctl", "list")
        assert re.search(rf"(?m)^{pid}\s+\d+\s+UIKitApplication:{re.escape(bundle)}\[", listing)
        print("Second launch: process alive and the original startup log is unchanged", flush=True)
    finally:
        queue.close()
        os.close(descriptor)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="UDID of a booted simulator with no Poki install")
    parser.add_argument("app", type=Path, help="path to the built Poki.app")
    args = parser.parse_args()
    check(args.device, args.app)
