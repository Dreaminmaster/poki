#!/bin/bash
# retry-flaky.sh COMMAND...: runs a check.sh command and, when it fails with one of the transient
# refusals a freshly booted Duo simulator gives on CI, runs it once more (check.sh makes a new
# simulator each time). Those refusals: the XCTest session does not open in time (session_timeout),
# the just-launched fixture's accessibility server is not up (kAXErrorServerNotFound), the display
# changes during the first picture, or the fixture is not in front yet. Any other failure, or the
# same failure twice, fails the step.
set -uo pipefail
LOG="$(mktemp "${TMPDIR:-/tmp}/poki-check-log.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
FLAKES="session_timeout|kAXErrorServerNotFound|display_changed_during_screenshot|front app: \\{'bundleId': 'local\\.poki\\.inprocess-check'"
status=0
for attempt in 1 2; do
  "$@" 2>&1 | tee "$LOG"
  status=${PIPESTATUS[0]}
  [ "$status" -eq 0 ] && exit 0
  grep -q -E "$FLAKES" "$LOG" || exit "$status"
  [ "$attempt" -eq 1 ] && echo "::warning::the simulator refused transiently ($(grep -o -m1 -E "$FLAKES" "$LOG")); running the check again on a new simulator"
done
exit "$status"
