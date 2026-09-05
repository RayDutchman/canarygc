#!/usr/bin/env bash
# CanaryGC HDMI-in push (RK3588)
#
# Source of truth: contrib/hdmi-in-push.sh in the canarygc fork
# (branch rk3588-support). Deployed to /usr/local/bin/hdmi-in-push.sh and run
# as hdmi-in-push.service. Edit the repo copy, never the deployed copy.
#
# Locates the rk_hdmirx capture node (node numbering drifts across boots),
# captures the HDMI RX signal and hardware-encodes it (h264_rkmpp) to an H.264
# RTSP stream on MediaMTX's `cam` path.
#
# Reliability design (the push pipeline must survive the field unattended):
# - waits for the rk_hdmirx node to appear (late driver probe at boot) instead
#   of exiting, so systemd never churns on a missing node;
# - polls for a valid DV timing and only runs ffmpeg while a signal exists;
#   mid-stream signal loss returns to polling automatically;
# - signal geometry/format is re-probed on every start (never hard-coded), so
#   a source that changes resolution or colorimetry mid-session is picked up;
# - consecutive instant ffmpeg failures back off (MediaMTX restarting, device
#   busy) instead of hot-spinning;
# - single-instance guard: a second copy (e.g. a manual test run) exits
#   quietly instead of fighting over /dev/video0;
# - Restart=on-failure in the unit is only a crash backstop for bugs, with
#   systemd start-limiting disabled so the backstop never parks the unit.
#
# Requires Armbian's ffmpeg built with --enable-rkmpp (h264_rkmpp). The RTSP
# target is MediaMTX which runs on the host network (:8554), sharing this
# board's 127.0.0.1.
set -euo pipefail

# ---- tunables (validated below; invalid values warn and fall back) ----
FPS="${FPS:-30}"
BITRATE="${BITRATE:-4000000}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"            # no-signal probe period (s)
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"          # wait after a healthy ffmpeg run ends (s)
NODE_POLL_INTERVAL="${NODE_POLL_INTERVAL:-5}"  # rk_hdmirx node wait period (s)
FAST_FAIL_WINDOW_S="${FAST_FAIL_WINDOW_S:-10}" # ffmpeg run shorter than this counts as a fast fail
MAX_FAST_FAILS="${MAX_FAST_FAILS:-5}"          # consecutive fast fails before...
LONG_BACKOFF_S="${LONG_BACKOFF_S:-30}"         # ...a long backoff (s)
# MediaMTX API host:port (cam path state). The watchdog polls it to detect a
# dropped RTSP push even when ffmpeg itself stays alive (a stuck half-closed
# socket); on loss it kills ffmpeg so the exporter restarts cleanly.
MEDIAMTX_API="${MEDIAMTX_API:-http://127.0.0.1:9997}"
RTSP_MONITOR_INTERVAL="${RTSP_MONITOR_INTERVAL:-4}"  # watchdog poll period (s)
RTSP_MONITOR_CONSEC="${RTSP_MONITOR_CONSEC:-2}"     # consecutive dead polls before kill

is_posint() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

# check_int <name> <value> <default>: print value, or warn + print default.
check_int() {
    if is_posint "$2"; then
        printf '%s' "$2"
    else
        echo "WARN: $1='$2' is not a positive integer, using default $3" >&2
        printf '%s' "$3"
    fi
}

FPS="$(check_int FPS "$FPS" 30)"
BITRATE="$(check_int BITRATE "$BITRATE" 4000000)"
POLL_INTERVAL="$(check_int POLL_INTERVAL "$POLL_INTERVAL" 2)"
RETRY_INTERVAL="$(check_int RETRY_INTERVAL "$RETRY_INTERVAL" 2)"
NODE_POLL_INTERVAL="$(check_int NODE_POLL_INTERVAL "$NODE_POLL_INTERVAL" 5)"
FAST_FAIL_WINDOW_S="$(check_int FAST_FAIL_WINDOW_S "$FAST_FAIL_WINDOW_S" 10)"
MAX_FAST_FAILS="$(check_int MAX_FAST_FAILS "$MAX_FAST_FAILS" 5)"
LONG_BACKOFF_S="$(check_int LONG_BACKOFF_S "$LONG_BACKOFF_S" 30)"
RTSP_MONITOR_INTERVAL="$(check_int RTSP_MONITOR_INTERVAL "$RTSP_MONITOR_INTERVAL" 4)"
RTSP_MONITOR_CONSEC="$(check_int RTSP_MONITOR_CONSEC "$RTSP_MONITOR_CONSEC" 2)"

# ---- preflight: fail fast with a clear message, systemd backstop restarts ----
for bin in v4l2-ctl ffmpeg; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "ERROR: required '$bin' not found in PATH" >&2
        exit 1
    }
done

# Single instance: a manual test run while the service is active exits quietly
# instead of racing it for the capture node. Locks never go stale (released on
# process death), and a normal exit does not trigger the on-failure restart.
exec 9>/run/hdmi-in-push.lock
if ! flock -n 9; then
    echo "another hdmi-in-push instance is already running, exiting" >&2
    exit 0
fi

# hdmirx node numbering drifts; pair the "rk_hdmirx" name line with its
# indented node line, like hdmiin-yolov5-kvm's scripts/kvm-direct.sh.
# Prints the node path, or nothing when the driver has no node (yet).
find_node() {
    local device="" line dev=""
    while IFS= read -r line; do
        if [[ "$line" == $'\t'* ]]; then
            if [[ -z "$dev" && "$device" == *"rk_hdmirx"* ]]; then
                dev="$(echo "$line" | tr -d '[:space:]')"
            fi
        else
            device="$line"
        fi
    done < <(v4l2-ctl --list-devices 2>/dev/null)
    printf '%s' "$dev"
}

# True when the node currently reports a valid HDMI signal. The output is
# captured to a variable first: with `set -o pipefail`, piping straight into
# `grep -q` races v4l2-ctl against SIGPIPE and can report "no signal" on a
# live source. No signal shows as `Link has been severed` (v4l2-ctl fails) or
# an all-zero timing (grep finds nothing) - both correctly read as false.
has_signal() {
    local out
    out="$(v4l2-ctl -d "$DEV" --query-dv-timings 2>&1)" || return 1
    grep -qE "Active width: [1-9][0-9]*" <<<"$out"
}

# One compact line per stream start (best effort, never fails the script).
describe_signal() {
    local fmt timings
    fmt="$(v4l2-ctl -d "$DEV" --get-fmt-video 2>/dev/null | grep -E "Width/Height|Pixel Format" | tr '\n' ' ' || true)"
    timings="$(v4l2-ctl -d "$DEV" --query-dv-timings 2>/dev/null | grep -E "Active width|Active height|frames per second" | tr '\n' ' ' || true)"
    printf '%s %s' "$fmt" "$timings"
    return 0
}

# Background watchdog: watch the ffmpeg PID and the MediaMTX cam path. When
# the RTSP push is no longer being accepted (cam online=false) the ffmpeg
# process may be stuck on a half-closed socket and never exit; SIGKILL it so
# the driver-facing EINVAL (or wait timeout) resolves and the main loop
# restarts.
rtsp_watchdog() {
    local pid="$1"
    local dead=0
    local on
    while kill -0 "$pid" 2>/dev/null; do
        # poll MediaMTX's per-path state; a missing/empty body counts as dead
        on="$(curl -fsS --max-time 3 "$MEDIAMTX_API/v3/paths/get/cam" 2>/dev/null \
            | grep -o '"online":[a-z]*' | head -1 || true)"
        if [[ "$on" == *'"online":true'* ]]; then
            dead=0
        else
            dead=$((dead + 1))
            if (( dead >= RTSP_MONITOR_CONSEC )); then
                echo "RTSP push lost to MediaMTX (online≠true x${dead}), killing ffmpeg ${pid}"
                kill -9 "$pid" 2>/dev/null || true
                return
            fi
        fi
        sleep "$RTSP_MONITOR_INTERVAL"
    done
}

push_stream() {
    # NOTE: do not pass -video_size/-pix_fmt for hdmirx - the driver reports the
    # source signal's native geometry/pixel format (bgr24 vs nv12) and cannot be
    # S_FMT-overridden. ffmpeg auto-detects and converts to NV12 for h264_rkmpp.
    # -rtsp_transport tcp is recommended: MediaMTX's rtspTransports default to
    # [udp, multicast, tcp], but over the internet or behind a firewall the UDP
    # SETUP can be dropped and browsers cannot receive UDP; TCP always works.
    # -nostdin: stdin is /dev/null under systemd; never let keypresses (or EOF
    # handling quirks) control a daemonized ffmpeg.
    # Run ffmpeg in the background and track its PID so the RTSP watchdog can
    # reap a stuck half-closed push; `wait` still returns its real exit code.
    ffmpeg -hide_banner -nostdin \
        -f v4l2 -framerate "$FPS" -i "$DEV" \
        -c:v h264_rkmpp -b:v "$BITRATE" \
        -maxrate "$BITRATE" -bufsize "$((BITRATE * 2))" \
        -rtsp_transport tcp \
        -f rtsp rtsp://127.0.0.1:8554/cam &
    local FFMPEG_PID=$!
    rtsp_watchdog "$FFMPEG_PID" &
    local WATCHDOG_PID=$!
    wait "$FFMPEG_PID"
    local RC=$?
    kill "$WATCHDOG_PID" 2>/dev/null || true
    return "$RC"
}

# Status flips are logged once each; steady state stays quiet.
LOST=1
NODE_WAIT_LOGGED=0
FAILS=0
while true; do
    DEV="$(find_node)"
    if [[ -z "$DEV" ]]; then
        if [[ "$NODE_WAIT_LOGGED" == "0" ]]; then
            echo "rk_hdmirx node absent (driver not probed yet?), waiting..."
            NODE_WAIT_LOGGED=1
        fi
        LOST=1
        sleep "$NODE_POLL_INTERVAL"
        continue
    fi
    NODE_WAIT_LOGGED=0

    if has_signal; then
        if [[ "$LOST" == "1" ]]; then
            echo "HDMI source detected ($DEV): $(describe_signal), starting push"
            LOST=0
        fi
        START_TS="$(date +%s)"
        if push_stream; then
            echo "ffmpeg exited cleanly, re-probing..."
            FAILS=0
            LOST=1
            sleep "$RETRY_INTERVAL"
        else
            RC=$?
            RUN_S=$(( $(date +%s) - START_TS ))
            if (( RUN_S < FAST_FAIL_WINDOW_S )); then
                FAILS=$((FAILS + 1))
            else
                FAILS=0
            fi
            LOST=1
            if (( FAILS >= MAX_FAST_FAILS )); then
                echo "ffmpeg failed ${FAILS}x in a row within ${FAST_FAIL_WINDOW_S}s (rc=$RC, MediaMTX down?), backing off ${LONG_BACKOFF_S}s..."
                sleep "$LONG_BACKOFF_S"
                FAILS=0
            else
                echo "ffmpeg exited rc=$RC after ${RUN_S}s (signal lost or error), re-probing..."
                sleep "$RETRY_INTERVAL"
            fi
        fi
    else
        if [[ "$LOST" == "0" ]]; then
            echo "no HDMI source signal, waiting..."
            LOST=1
        fi
        sleep "$POLL_INTERVAL"
    fi
done
