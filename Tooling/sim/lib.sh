# Sourced by the scripts beside it. Bash 3.2: macOS ships nothing newer, and no `timeout`.

SIM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SIM_DIR/lane.env"

BRIDGE=http://127.0.0.1:8765

# Chosen from what the machine actually has: device lists change between images, and a hardcoded
# name fails late and confusingly.
sim_pick_device() {
  xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
for runtime in sorted(devices, reverse=True):
    if 'iOS' not in runtime: continue
    for d in devices[runtime]:
        if d.get('isAvailable') and 'iPhone' in d['name']:
            print(d['udid']); raise SystemExit
"
}

# `bootstatus -b` can wait forever on a simulator that hung during boot, so it runs in the
# background under a deadline. Returns non-zero when the deadline passes.
sim_wait_booted() {
  local udid=$1 deadline=$((SECONDS + $2)) pid
  xcrun simctl bootstatus "$udid" -b > /dev/null &
  pid=$!
  while kill -0 "$pid" 2> /dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$pid" 2> /dev/null
      wait "$pid" 2> /dev/null
      return 1
    fi
    sleep 2
  done
  wait "$pid"
}

sim_find_app() {
  find "$1/Build/Products" -name '*.app' -maxdepth 3 | head -1
}

# Screenshots the simulator into $2. A simulator with more than one display makes
# `simctl io screenshot` refuse without `--display`; each display then goes to
# `<name>-display<id>.png` and the largest of them is copied to $2.
sim_screenshot() {
  local udid=$1 out=$2 err ids d f bytes best="" best_bytes=0
  if err=$(xcrun simctl io "$udid" screenshot "$out" 2>&1); then return 0; fi
  ids=$(printf '%s\n' "$err" | sed -n 's/.*--display=\([0-9][0-9]*\).*/\1/p')
  if [ -z "$ids" ]; then
    printf '%s\n' "$err" >&2
    return 1
  fi
  for d in $ids; do
    f="${out%.png}-display$d.png"
    xcrun simctl io "$udid" screenshot --display="$d" "$f" > /dev/null 2>&1 || continue
    bytes=$(stat -f %z "$f")
    if [ "$bytes" -gt "$best_bytes" ]; then
      best=$f
      best_bytes=$bytes
    fi
  done
  [ -n "$best" ] && cp "$best" "$out"
}

# Size of a file in bytes, 0 when it does not exist.
file_bytes() {
  stat -f %z "$1" 2> /dev/null || echo 0
}
