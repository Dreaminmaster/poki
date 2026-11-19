#!/usr/bin/env python3
"""End-to-end check of the bridge on a Mac without an iPhone.

Starts poki-setup-bridge, talks to it over its pipe as the app does, and checks:
- it answers app_info and account;
- sign-in reaches Apple and Apple answers (for a made-up Apple Account: "wrong Apple Account or
  password", "locked" once Apple locks it, or since 2026-11 its IDMS server error with HTTP status
  500; not -80045, which means Apple refused our identity data);
- phones answers (an empty list on CI, since no iPhone is attached);
- bad input gives a readable error, and the helper keeps running.
"""
import json, os, subprocess, sys, tempfile, threading, time

bridge = sys.argv[1]
home = tempfile.mkdtemp(prefix="poki-e2e-")
env = dict(os.environ, HOME=home, POKI_SETUP_FILE_SECRETS="1", RUST_LOG="poki_setup_core=info")
p = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, bufsize=1)

# The helper's log still goes to this script's stderr; it is also kept, because the HTTP status
# Apple answered with is only in the log ("Apple sign-in status ec=... hsc=..."), not in the reply.
log = []
def forward_log():
    for line in p.stderr:
        sys.stderr.write(line)
        log.append(line)
threading.Thread(target=forward_log, daemon=True).start()

def logged(pred, timeout=5):
    # The log line is written before the reply, but on another pipe, so it can arrive a little later.
    end = time.time() + timeout
    while time.time() < end:
        if any(pred(l) for l in list(log)):
            return True
        time.sleep(0.1)
    return False

def read_until(pred, timeout=120):
    end = time.time() + timeout
    while time.time() < end:
        line = p.stdout.readline()
        if not line:
            raise SystemExit("bridge closed its output")
        msg = json.loads(line)
        if pred(msg):
            return msg
    raise SystemExit("timed out")

def call(i, cmd, args=None, timeout=120):
    p.stdin.write(json.dumps({"id": i, "cmd": cmd, "args": args or {}}) + "\n")
    p.stdin.flush()
    return read_until(lambda m: m.get("id") == i, timeout)

failures = []
def check(name, ok, detail):
    print(("PASS " if ok else "FAIL ") + name + ": " + json.dumps(detail)[:400])
    if not ok:
        failures.append(name)

read_until(lambda m: m.get("event") == "ready", 30)
r = call(1, "app_info")
check("app_info", "ok" in r and r["ok"]["os"] == "macos", r)
r = call(2, "account")
check("account (signed out)", "ok" in r and r["ok"]["signed_in"] is False, r)
for attempt in range(3):
    r = call(3 + attempt, "sign_in", {"apple_id": "poki.setup.ci.nobody@example.com", "password": "not-a-real-password-1A", "keep_password": False}, 180)
    msg = r.get("err", {}).get("message", "")
    if "cannot be completed" not in msg:
        break
# Since 2026-11 Apple answers a sign-in for an Apple Account that does not exist with hsc 500 and
# "Unexpected response from IDMS Server" instead of "wrong password". That answer still proves the
# request reached Apple and Apple replied, so it passes; the output says which answer Apple gave.
# No network, no anisette data or a helper that died give another kind or no reply, and fail.
err = r.get("err", {})
text = err.get("message", "").lower() if err.get("kind") == "apple" else ""
if "wrong" in text:
    answer = "wrong Apple Account or password"
elif "locked" in text:
    answer = "Apple Account locked"
elif "idms server" in text and logged(lambda l: "Apple sign-in status" in l and "hsc=500" in l):
    answer = "IDMS server error, hsc 500 (Apple's answer for an Apple Account that does not exist since 2026-11)"
else:
    answer = None
check("sign-in reaches Apple, Apple answers" + (f" ({answer})" if answer else ""), answer is not None, r)
r = call(10, "phones")
check("phones answers", "ok" in r or r.get("err", {}).get("kind") == "usbmuxd", r)
r = call(11, "connector_snippets", {"url": "not a link"})
check("bad input is a readable error", "err" in r and r["err"]["message"], r)
r = call(12, "ping")
check("helper still running", r.get("ok") == "pong", r)
p.stdin.close()
p.wait(10)
if failures:
    raise SystemExit("failed: " + ", ".join(failures))
print("all checks passed")
