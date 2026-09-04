#!/usr/bin/env bash
# CanaryGC HDMI-in push (RK3588)
#
# Locates the rk_hdmirx capture node (node numbering drifts across boots),
# captures the HDMI RX signal and hardware-encodes it (h264_rkmpp) to an H.264
# RTSP stream on MediaMTX's `cam` path. Intended to run as the
# `hdmi-in-push.service` systemd unit (Restart=always drives hot-plug
# self-healing): when no HDMI source is attached, ffmpeg exits and systemd
# retries until a signal appears.
#
# Requires Armbian's ffmpeg built with --enable-rkmpp (h264_rkmpp). The RTSP
# target is MediaMTX which runs on the host network (:8554), sharing this
# board's 127.0.0.1.
set -euo pipefail

# hdmirx node numbering drifts; pair the "rk_hdmirx" name line with its
# indented node line, like hdmiin-yolov5-kvm's scripts/kvm-direct.sh.
DEV=""
device=""
while IFS= read -r line; do
    if [[ "$line" == $'\t'* ]]; then
        if [[ -z "$DEV" && "$device" == *"rk_hdmirx"* ]]; then
            DEV="$(echo "$line" | tr -d '[:space:]')"
        fi
    else
        device="$line"
    fi
done < <(v4l2-ctl --list-devices 2>/dev/null)

if [[ -z "$DEV" ]]; then
    echo "ERROR: rk_hdmirx capture node not found" >&2
    exit 1
fi
echo "hdmirx node: $DEV"

# Optional overrides (encoded as simple integers):
#   FPS, WIDTH, HEIGHT, BITRATE (bps)
FPS="${FPS:-30}"
BITRATE="${BITRATE:-4000000}"

# NOTE: do not pass -video_size/-pix_fmt for hdmirx - the driver reports the
# source signal's native geometry/pixel format (bgr24 vs nv12) and cannot be
# S_FMT-overridden. ffmpeg auto-detects and converts to NV12 for h264_rkmpp.
# -rtsp_transport tcp is recommended: MediaMTX's rtspTransports default to
# [udp, multicast, tcp], but over the internet or behind a firewall the UDP
# SETUP can be dropped and browsers cannot receive UDP; TCP always works.
exec ffmpeg -hide_banner \
    -f v4l2 -framerate "$FPS" -i "$DEV" \
    -c:v h264_rkmpp -b:v "$BITRATE" \
    -maxrate "$BITRATE" -bufsize "$((BITRATE * 2))" \
    -rtsp_transport tcp \
    -f rtsp rtsp://127.0.0.1:8554/cam
