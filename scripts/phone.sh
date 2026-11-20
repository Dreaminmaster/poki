#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/phone.sh device IPHONE_UDID TEAM_ID BUNDLE_ID APP_GROUP [--built-in]
  scripts/phone.sh simulator BOOTED_SIMULATOR_UDID

The device build uses automatic development signing. It defaults to PokiExternal.
See docs/install-from-source-agent-prompt.md for prerequisites and signing.
EOF
}

if [[ ${1:-} == --help ]]; then
  usage
  exit 0
fi

mode=${1:-}
destination=${2:-}
spec=project-external.yml
project=PokiExternal
case "$mode" in
  device)
    if [[ $# -lt 5 || $# -gt 6 || ( $# -eq 6 && $6 != --built-in ) ]]; then
      usage >&2
      exit 2
    fi
    if [[ ${6:-} == --built-in ]]; then
      spec=project.yml
      project=Poki
    fi
    sdk=iphoneos
    rust_target=aarch64-apple-ios
    build_destination="platform=iOS,id=$destination"
    signing=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
      "DEVELOPMENT_TEAM=$3" CODE_SIGN_STYLE=Automatic 'CODE_SIGN_IDENTITY=Apple Development'
      "POKI_BUNDLE_ID=$4" "POKI_APP_GROUP=$5")
    ;;
  simulator)
    if [[ $# -ne 2 ]]; then
      usage >&2
      exit 2
    fi
    sdk=iphonesimulator
    rust_target=aarch64-apple-ios-sim
    build_destination="platform=iOS Simulator,id=$destination"
    signing=(CODE_SIGNING_ALLOWED=NO "POKI_BUNDLE_ID=local.poki.source" "POKI_APP_GROUP=group.local.poki.source")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
umask 077
out="$root/build/phone/$project-$sdk"
mkdir -p "$out"
run=$(mktemp -d "$out/run.XXXXXXXX")
log="$run/phone.log"
echo "Log file $log"

fail() {
  echo "$1 See $log." >&2
  exit 1
}

step() {
  local label=$1 started=$SECONDS
  shift
  printf '%s\n' "$label"
  if ! "$@" >>"$log" 2>&1; then
    fail "$label failed after $((SECONDS - started))s."
  fi
  printf '  Done in %ss\n' "$((SECONDS - started))"
}

check_destination() {
  if [[ $mode == device ]]; then
    xcrun devicectl list devices --timeout 15 --json-output "$run/devices.json" || return
    python3 - "$destination" "$run/devices.json" <<'PY'
import json, sys

udid, path = sys.argv[1:]
with open(path) as source:
    devices = json.load(source)["result"]["devices"]
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if (hardware.get("udid", "").lower() == udid.lower()
            and hardware.get("deviceType") == "iPhone"
            and connection.get("transportType") == "wired"
            and connection.get("pairingState") == "paired"):
        if device.get("deviceProperties", {}).get("developerModeStatus") == "disabled":
            sys.exit("Enable Developer Mode, restart the iPhone, and confirm after it restarts.")
        break
else:
    sys.exit("Connect the specified iPhone over USB, unlock it, and accept Trust This Computer.")
PY
  else
    xcrun simctl list devices booted -j >"$run/devices.json" || return
    python3 - "$destination" "$run/devices.json" <<'PY'
import json, sys

udid, path = sys.argv[1:]
with open(path) as source:
    runtimes = json.load(source)["devices"]
if not any(item["udid"].lower() == udid.lower()
           for runtime, devices in runtimes.items()
           if runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
           for item in devices):
    sys.exit("Boot the specified iOS simulator before running this script.")
PY
  fi
}

collect_crash() {
  local report
  if ! xcrun devicectl device info files --device "$destination" --domain-type systemCrashLogs \
    --timeout 20 --json-output "$run/crashes.json" >>"$log" 2>&1; then
    echo "Could not read iPhone crash reports." >&2
    return
  fi
  report=$(python3 - "$run/crashes.json" "$executable" "$launched_at" <<'PY'
import datetime, json, sys

path, executable, launched_at = sys.argv[1:]
with open(path) as source:
    files = json.load(source)["result"]["files"]
reports = []
for item in files:
    if not item["name"].startswith(executable + "-") or not item["name"].endswith(".ips"):
        continue
    modified = item.get("metadata", {}).get("lastModDate")
    if modified and item.get("relativePath"):
        timestamp = datetime.datetime.fromisoformat(modified.replace("Z", "+00:00")).timestamp()
        if timestamp >= int(launched_at):
            reports.append((timestamp, item["relativePath"]))
if reports:
    print(max(reports)[1])
PY
  ) || return
  if [[ -z $report ]]; then
    echo "No new Poki crash report is available yet." >&2
  elif xcrun devicectl device copy from --device "$destination" --domain-type systemCrashLogs \
    --source "$report" --destination "$run/$(basename "$report")" --timeout 20 >>"$log" 2>&1; then
    echo "Saved crash report in $run" >&2
  else
    echo "Could not copy the Poki crash report." >&2
  fi
}

step "Check destination" check_destination
step "Fetch PokiLauncher dependency" native/launcher/fetch-idevice.sh
step "Build PokiLauncher" /usr/bin/env "CARGO_TARGET_DIR=$root/native/launcher/target" \
  cargo +stable build --release --locked --target "$rust_target" --manifest-path native/launcher/Cargo.toml
step "Generate app assets" native/ios-app/scripts/make-assets.sh
step "Generate Xcode project" xcodegen generate --use-cache --spec "native/ios-app/$spec"
step "Build Poki" xcodebuild build -project "native/ios-app/$project.xcodeproj" -scheme Poki \
  -configuration Debug -destination "$build_destination" -derivedDataPath "$out/DerivedData" \
  ARCHS=arm64 "${signing[@]}"

app="$out/DerivedData/Build/Products/Debug-$sdk/Poki.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist" 2>>"$log") \
  || fail "Could not read the built app's bundle ID."
if [[ $mode == device ]]; then
  executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist" 2>>"$log") \
    || fail "Could not read the built app's executable."
  step "Install Poki on iPhone" xcrun devicectl device install app --device "$destination" "$app" --timeout 120
  launched_at=$(date +%s)
  step "Launch Poki on iPhone" xcrun devicectl device process launch --device "$destination" \
    --terminate-existing --timeout 30 --json-output "$run/launch.json" "$bundle"
  sleep 5
  step "Read running iPhone processes" xcrun devicectl device info processes --device "$destination" \
    --timeout 20 --json-output "$run/processes.json"
  verdict=$(python3 - "$run" <<'PY'
import json, pathlib, sys

run = pathlib.Path(sys.argv[1])
with (run / "launch.json").open() as source:
    pid = json.load(source)["result"]["process"]["processIdentifier"]
with (run / "processes.json").open() as source:
    processes = json.load(source)["result"]["runningProcesses"]
print("running" if any(item["processIdentifier"] == pid for item in processes) else "exited")
PY
  ) || fail "Could not verify the iPhone launch."
  if [[ $verdict == exited ]]; then
    collect_crash || true
    fail "Poki exited within five seconds. If a report has not appeared, check systemCrashLogs again."
  fi
else
  step "Install Poki on simulator" xcrun simctl install "$destination" "$app"
  launched_at=$SECONDS
  echo "Launch Poki on simulator"
  if ! launch=$(xcrun simctl launch --terminate-running-process "$destination" "$bundle" 2>>"$log"); then
    fail "Launch on simulator failed."
  fi
  printf '%s\n' "$launch" >>"$log"
  printf '  Done in %ss\n' "$((SECONDS - launched_at))"
  pid=${launch##* }
  sleep 5
  step "Read running simulator processes" bash -c 'xcrun simctl spawn "$1" launchctl list >"$2"' \
    _ "$destination" "$run/processes.txt"
  if ! awk -v pid="$pid" '$1 == pid { found = 1 } END { exit !found }' "$run/processes.txt"; then
    fail "Poki exited within five seconds. Look for a Poki report in ~/Library/Logs/DiagnosticReports."
  fi
fi
echo "Poki is still running five seconds after launch."
