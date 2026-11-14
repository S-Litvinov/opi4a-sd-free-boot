# Appendix: "No signal" on HDMI after booting (and the on-demand GUI console)

You revived the board from SPI+NVMe, plugged a monitor in to celebrate — and the TV says
**No signal**, while SSH works perfectly. Do not panic, nothing is broken, and this is not
regression from the boot-chain work. It is a property of the vendor BSP kernel itself:
it does the same on the stock SD boot after ~30 s of TV standby.

## Root cause (verified on hardware, 5.15.147-sun55iw3)

The kernel binds the sunxi DRM driver (~2 s into boot) **before** the HDMI block reports
HPD/EDID. Deterministic kernel signature:

```
[drm] de use no display sys
[drm:sunxi_drm_bind] *ERROR* none mode found init_connecting
sunxi-drm ...: [drm] Cannot find any crtc or sizes
```

Consequences:

- no framebuffer (`/dev/fb*` absent) → no fbcon → **a kernel text console on HDMI is
  impossible on this BSP**, in any boot mode;
- on a headless system nobody ever becomes DRM master, so no mode is ever set → the panel
  never gets sync → "No signal";
- the connector *status* lies if you misread it:
  `/sys/class/drm/card0-HDMI-A-1/status` = `connected` (that is just DDC/EDID, which works
  with the video pipeline off), while `cat .../modes` is **empty**.

Proof that the link itself is fine:

```bash
sudo apt-get install -y libdrm-tests
modetest -M sunxi-drm -D /dev/dri/card0 | grep -c '^  #'   # ~43-45 modes: enumeration WORKS
# watch the TV while this runs for 10 s (color bars, then black WITH sync):
timeout 10 modetest -M sunxi-drm -D /dev/dri/card0 -s <connector_id>:1920x1080-60
```

(refresh uses a dash, not `@`; connector id is the first column of the HDMI row in the
`modetest` listing). After modetest exits, the mode stays enabled — black picture with
valid sync, i.e. "No signal" is gone forever as long as someone set a mode.

Do **not** "fix" this with `sunxi-drm` unbind/bind experiments: 5 unbind/bind cycles in a
row hard-hang this board (power cycle required). One max.

## The good fix: an on-demand graphical console (`weston-hdmi.service`)

Since a compositor sets the mode itself (and runs a few seconds later than the kernel bind,
when modes already enumerate), you can get a real fullscreen terminal on the TV on demand.
This beats the modetest trick: it is an actual emergency console, with a shell, running
over llvmpipe — or, as a nice surprise, over the real **Mali-G57 via panfrost**: the vendor
kernel exposes `/dev/dri/renderD128` and Mesa uses it out of the box.

One-time install (root):

```bash
apt-get install -y weston xterm fonts-dejavu-core libegl-mesa0 libgl1-mesa-dri seatd
# Ubuntu seatd runs `seatd -g video` — your kiosk user must be in group `video`
systemctl enable --now seatd.service
loginctl enable-linger <USER>          # keeps /run/user/<UID> alive always
install -m 0644 weston-hdmi.ini /etc/weston-hdmi.ini
install -m 0644 weston-hdmi.service /etc/systemd/system/weston-hdmi.service
install -m 0755 hdmi-term-client.sh /usr/local/bin/hdmi-term-client.sh
# edit User=/UID paths in the unit + client script for your user (placeholders <USER>/<UID>)
systemctl daemon-reload
```

Usage:

```bash
sudo systemctl start weston-hdmi   # ~10 s later: dark fullscreen xterm (bash) on HDMI
sudo systemctl stop weston-hdmi    # release the TV; seatd restores the VT
```

The unit is deliberately **not enabled** — headless boots never touch video.

Files here: `hdmi-kiosk/weston-hdmi.service`, `hdmi-kiosk/weston-hdmi.ini`,
`hdmi-kiosk/hdmi-term-client.sh`.

### Pitfalls that cost the most time (all verified the hard way)

1. **Do not put `TTYPath=` / `StandardInput=tty` / `PAMName=` into the weston unit.**
   With systemd owning the tty, seatd cannot grab the VT and weston exits in <1 s
   *completely silently* (no journal, no log file). A plain unprivileged process **without**
   a controlling tty works — that is the shipped unit shape.
2. A PAM service session (`PAMName=login`) does get a logind session, but logind usually
   assigns it **no seat** (`libseat: failed to open seat: No data available`). Do not fight
   logind; just run `seatd` (libseat tries seatd → logind → builtin, in that order).
3. Without `libgl1-mesa0`/`libgl1-mesa-dri` there is no `/usr/lib/dri` at all and weston
   dies; with them, GL init succeeds on Mali-G57/panfrost.
4. weston's log vanishes into the journal (JOURNAL_STREAM) — pass `--log=/tmp/weston-hdmi.log`.
5. Client startup belongs in a separate script backgrounded from `ExecStartPost` — inline
   xterm args inside the unit are a triple-quoting trap, and a foreground
   `ExecStartPost` parks the unit in "start-post" until `TimeoutStartSec` kills everything.
6. `xterm` has **no** `-cursorColor` option (it prints usage and exits) — use
   `-xrm '*.cursorColor: #58a6ff'`.
7. If weston is also silent and instant-exit and you cannot see why, run it manually the
   same way the unit runs it — from SSH as the same user:
   `setsid weston --backend=drm ... --log=/tmp/w2.log &` (no controlling tty is exactly
   what the unit gives it).

## What about booting the TV "cold", would bind ever win?

Tested: TV already powered, cable in, full power cycle — bind still finds nothing
(`none mode found`), every time, several boots. If some display family does make the
kernel win the race, it would just work natively; nothing here gets in its way, since the
kiosk unit is not enabled and nothing at boot touches DRM.
