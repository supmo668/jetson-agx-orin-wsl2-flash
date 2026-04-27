#!/usr/bin/env bash
# Prepare the JetPack 6.2 rootfs for flashing.
#
# Steps:
#   1. Sanity-check the downloaded sample rootfs tarball.
#   2. Extract it into Linux_for_Tegra/rootfs/ (PRESERVING xattrs/file caps).
#   3. Run apply_binaries.sh
#   4. Run l4t_create_default_user.sh (so the flashed image doesn't run oem-config)
#   5. Install jetson-firstboot.service into the rootfs (self-heal on first boot)
#   6. (Optional) chroot into rootfs and reinstall snapd so file caps land
#      INSIDE the image before flashing — this is the upstream fix that prevents
#      the post-flash "snap-confine missing cap_dac_override" failure.
#
# Usage:
#   sudo ./prepare_rootfs.sh
#
# Configuration via env vars:
#   BSP_DIR        — absolute path to Linux_for_Tegra (default: $PWD/Linux_for_Tegra)
#   ROOTFS_TBZ     — absolute path to Tegra_Linux_Sample-Root-Filesystem_*.tbz2
#   JETSON_USER    — default user (login name on the flashed Orin)
#   JETSON_PASS    — default password (CHANGE THIS — do not ship credentials)
#   JETSON_HOST    — hostname
#   SKIP_SNAP_FIX  — set to "1" to skip the chroot-based snapd reinstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BSP_DIR="${BSP_DIR:-$(pwd)/Linux_for_Tegra}"
ROOTFS_TBZ="${ROOTFS_TBZ:-$(pwd)/tegra_linux_sample-root-filesystem_r36.4.3_aarch64.tbz2}"

JETSON_USER="${JETSON_USER:-nvidia}"
JETSON_PASS="${JETSON_PASS:-changeme}"
JETSON_HOST="${JETSON_HOST:-jetson-agx-orin}"

SKIP_SNAP_FIX="${SKIP_SNAP_FIX:-0}"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

if [[ ! -d "$BSP_DIR" ]]; then
  echo "BSP not found at: $BSP_DIR" >&2
  echo "Set BSP_DIR or run from a directory containing Linux_for_Tegra/." >&2
  exit 1
fi

if [[ ! -f "$ROOTFS_TBZ" ]]; then
  echo "Sample rootfs tarball not found: $ROOTFS_TBZ" >&2
  echo "Download from: https://developer.nvidia.com/embedded/jetson-linux-r3643" >&2
  exit 1
fi

echo "[1/6] Verifying tarball integrity…"
bzip2 -t "$ROOTFS_TBZ"

echo "[2/6] Extracting sample rootfs into $BSP_DIR/rootfs/ (preserving xattrs)…"
cd "$BSP_DIR/rootfs"
if [[ "$(ls | grep -v '^README.txt$' || true)" ]]; then
  echo "rootfs/ already contains files. Refusing to overwrite — clear it manually." >&2
  exit 1
fi
# --xattrs and --xattrs-include='*' preserve security.capability xattrs (file caps).
# Without this, snap-confine, ping, and other cap-bearing binaries lose their
# capabilities on the flashed image.
tar --xattrs --xattrs-include='*' -xpf "$ROOTFS_TBZ"

echo "[3/6] Running apply_binaries.sh …"
cd "$BSP_DIR"
./apply_binaries.sh

echo "[4/6] Creating default user '$JETSON_USER' @ '$JETSON_HOST' …"
./tools/l4t_create_default_user.sh \
  -u "$JETSON_USER" \
  -p "$JETSON_PASS" \
  -n "$JETSON_HOST" \
  --accept-license

echo "[5/6] Installing jetson-firstboot self-heal service into rootfs…"
install -m 0755 "$SCRIPT_DIR/jetson-firstboot.sh" \
    "$BSP_DIR/rootfs/usr/local/sbin/jetson-firstboot.sh"
install -m 0644 "$SCRIPT_DIR/jetson-firstboot.service" \
    "$BSP_DIR/rootfs/etc/systemd/system/jetson-firstboot.service"
mkdir -p "$BSP_DIR/rootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/jetson-firstboot.service \
    "$BSP_DIR/rootfs/etc/systemd/system/multi-user.target.wants/jetson-firstboot.service"

if [[ "$SKIP_SNAP_FIX" == "1" ]]; then
  echo "[6/6] Skipping chroot-based snapd repair (SKIP_SNAP_FIX=1)."
else
  echo "[6/6] Repairing snapd inside the rootfs via aarch64 chroot…"
  if [[ ! -x "$BSP_DIR/rootfs/usr/bin/qemu-aarch64-static" ]]; then
    echo "      qemu-aarch64-static not found in rootfs — copying from host"
    if [[ -x /usr/bin/qemu-aarch64-static ]]; then
      cp /usr/bin/qemu-aarch64-static "$BSP_DIR/rootfs/usr/bin/qemu-aarch64-static"
    else
      echo "      WARNING: qemu-user-static not installed on host. Install with:"
      echo "          sudo apt install qemu-user-static binfmt-support"
      echo "      Skipping chroot fix — relying on first-boot self-heal."
      SKIP_SNAP_FIX=1
    fi
  fi

  if [[ "$SKIP_SNAP_FIX" != "1" ]]; then
    # Bind-mount the kernel interfaces so apt/dpkg work in the chroot.
    for d in proc sys dev dev/pts run; do
      mount --bind "/$d" "$BSP_DIR/rootfs/$d" 2>/dev/null || true
    done
    cleanup_chroot() {
      for d in run dev/pts dev sys proc; do
        umount -lf "$BSP_DIR/rootfs/$d" 2>/dev/null || true
      done
    }
    trap cleanup_chroot EXIT

    cp /etc/resolv.conf "$BSP_DIR/rootfs/etc/resolv.conf" 2>/dev/null || true

    chroot "$BSP_DIR/rootfs" /bin/bash -c '
      set -e
      echo "Inside chroot: reinstalling snapd to land file capabilities…"
      DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y snapd || true
      if [ -f /usr/lib/snapd/snap-confine ]; then
        if ! getcap /usr/lib/snapd/snap-confine 2>/dev/null | grep -q cap_dac_override; then
          echo "  reinstall did not set caps — applying setcap directly"
          setcap "cap_audit_write,cap_dac_override,cap_dac_read_search,cap_fowner,cap_kill,cap_net_admin,cap_setgid,cap_setuid,cap_sys_admin,cap_sys_chroot,cap_sys_resource=ep" /usr/lib/snapd/snap-confine
        fi
        echo "  snap-confine: $(getcap /usr/lib/snapd/snap-confine)"
      fi
    ' || echo "      chroot snap-fix failed — first-boot self-heal will retry"

    cleanup_chroot
    trap - EXIT
  fi
fi

cat <<EOF

Done. BSP is ready at $BSP_DIR

Layered protection against snap-cap loss:
  Layer 1: tar --xattrs preserved caps from the upstream tarball
  Layer 2: chroot reinstall of snapd put caps in the rootfs (if applicable)
  Layer 3: jetson-firstboot.service will repair on first boot if anything slipped

Next step (with Orin in Force Recovery Mode + usbipd attached):
    sudo ./flash_orin_nvme.sh
EOF
