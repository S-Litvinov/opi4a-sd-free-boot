#!/bin/sh
# hdmi-term-client: waits for the weston kiosk socket, then opens the dark
# xterm console (Xwayland) with weston-terminal as fallback. Installed to
# /usr/local/bin; run BACKGROUNDed by weston-hdmi.service ExecStartPost
# (inline client args in ExecStartPost = quoting hell + start-post timeouts;
#  separate script keeps the unit active(RUNNING) and stops cleanly).
SOCK=/run/user/<UID>/hdmi
RT=/run/user/<UID>
i=0
while [ ! -S "$SOCK" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
[ -S "$SOCK" ] || { echo "no weston socket" >&2; exit 1; }
exec 2>/tmp/hdmi-term-client.log
env DISPLAY=:0 XDG_RUNTIME_DIR=$RT /usr/bin/xterm \
    -fa Monospace -fs 16 +sb \
    -bg '#0d1117' -fg '#e6edf3' \
    -xrm '*.cursorColor: #58a6ff' \
    -T 'emergency console' \
    -e bash --login \
 || env WAYLAND_DISPLAY=hdmi XDG_RUNTIME_DIR=$RT /usr/bin/weston-terminal
