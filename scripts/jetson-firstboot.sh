#!/usr/bin/env bash
# Self-heal script that runs ONCE on first boot of a freshly flashed Jetson.
# Repairs the things L4T's flash pipeline breaks:
#   - File capabilities on snap-confine (xattrs lost during image build)
#   - Snap mount prerequisites (squashfs, loop modules)
#   - Failed snap mount units (because the above were missing at first start)
#
# Installed into /usr/local/sbin/ by prepare_rootfs.sh and gated by
# jetson-firstboot.service. Runs once, marks itself complete, then disables.
#
# Logs to /var/log/jetson-firstboot.log so you can audit afterward.

set -euo pipefail

LOGFILE=/var/log/jetson-firstboot.log
exec >>"$LOGFILE" 2>&1
echo "=== jetson-firstboot $(date -u +%FT%TZ) ==="

STAMP=/var/lib/jetson-firstboot.done
if [[ -f "$STAMP" ]]; then
  echo "Already ran on $(cat "$STAMP"). Exiting."
  exit 0
fi

# --- 1. Make sure squashfs + loop are loadable. Snap mounts depend on these. ---
modprobe squashfs 2>/dev/null || echo "squashfs modprobe failed (may be built-in — fine)"
modprobe loop     2>/dev/null || echo "loop modprobe failed (may be built-in — fine)"

# --- 2. Wait for snapd to come up (or start it). ---
systemctl is-active --quiet snapd || systemctl start snapd || true
for _ in $(seq 1 30); do
  systemctl is-active --quiet snapd && break
  sleep 1
done

# --- 3. Verify and restore snap-confine file capabilities. ---
SNAP_CONFINE=/usr/lib/snapd/snap-confine
SNAP_CAPS='cap_audit_write,cap_dac_override,cap_dac_read_search,cap_fowner,cap_kill,cap_net_admin,cap_setgid,cap_setuid,cap_sys_admin,cap_sys_chroot,cap_sys_resource=ep'

if [[ -f "$SNAP_CONFINE" ]]; then
  current_caps="$(getcap "$SNAP_CONFINE" 2>/dev/null || true)"
  if ! grep -q cap_dac_override <<<"$current_caps"; then
    echo "snap-confine missing caps — reinstalling snapd to repair"
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y snapd || true

    # Belt and suspenders — explicit setcap if reinstall didn't restore them.
    if ! getcap "$SNAP_CONFINE" 2>/dev/null | grep -q cap_dac_override; then
      echo "Reinstall did not restore caps — applying setcap directly"
      setcap "$SNAP_CAPS" "$SNAP_CONFINE"
    fi
    systemctl restart snapd || true
  fi
  echo "snap-confine final: $(getcap "$SNAP_CONFINE")"
else
  echo "snap-confine not present — skipping (no snapd installed)"
fi

# --- 4. Restart any snap mount units that failed during early boot. ---
systemctl daemon-reload
systemctl reset-failed
mapfile -t failed_snaps < <(systemctl list-units --failed --no-legend --plain 2>/dev/null | awk '/^snap-/ {print $1}')
if (( ${#failed_snaps[@]} > 0 )); then
  echo "Restarting failed snap units: ${failed_snaps[*]}"
  for u in "${failed_snaps[@]}"; do
    systemctl restart "$u" || true
  done
fi

# --- 5. Mark done and disable self. ---
date -u +%FT%TZ > "$STAMP"
echo "=== jetson-firstboot complete ==="

systemctl disable jetson-firstboot.service 2>/dev/null || true
