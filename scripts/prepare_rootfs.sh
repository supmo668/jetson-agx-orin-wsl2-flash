#!/usr/bin/env bash
# Prepare the JetPack 6.2 rootfs for flashing.
#
# Steps:
#   1. Sanity-check the downloaded sample rootfs tarball.
#   2. Extract it into Linux_for_Tegra/rootfs/
#   3. Run apply_binaries.sh
#   4. Run l4t_create_default_user.sh (so the flashed image doesn't run oem-config)
#
# Usage:
#   sudo ./prepare_rootfs.sh
#
# Configuration via env vars (override defaults at the top):
#   BSP_DIR     — absolute path to the Linux_for_Tegra directory
#   ROOTFS_TBZ  — absolute path to Tegra_Linux_Sample-Root-Filesystem_*.tbz2
#   JETSON_USER — default user (login name on the flashed Orin)
#   JETSON_PASS — default password (CHANGE THIS — do not ship credentials)
#   JETSON_HOST — hostname

set -euo pipefail

BSP_DIR="${BSP_DIR:-$(pwd)/Linux_for_Tegra}"
ROOTFS_TBZ="${ROOTFS_TBZ:-$(pwd)/tegra_linux_sample-root-filesystem_r36.4.3_aarch64.tbz2}"

JETSON_USER="${JETSON_USER:-nvidia}"
JETSON_PASS="${JETSON_PASS:-changeme}"
JETSON_HOST="${JETSON_HOST:-jetson-agx-orin}"

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

echo "[1/4] Verifying tarball integrity…"
bzip2 -t "$ROOTFS_TBZ"

echo "[2/4] Extracting sample rootfs into $BSP_DIR/rootfs/ …"
cd "$BSP_DIR/rootfs"
if [[ "$(ls | grep -v '^README.txt$' || true)" ]]; then
  echo "rootfs/ already contains files. Refusing to overwrite — clear it manually." >&2
  exit 1
fi
tar xpf "$ROOTFS_TBZ"

echo "[3/4] Running apply_binaries.sh …"
cd "$BSP_DIR"
./apply_binaries.sh

echo "[4/4] Creating default user '$JETSON_USER' @ '$JETSON_HOST' …"
./tools/l4t_create_default_user.sh \
  -u "$JETSON_USER" \
  -p "$JETSON_PASS" \
  -n "$JETSON_HOST" \
  --accept-license

cat <<EOF

Done. BSP is ready at $BSP_DIR

Next step (with Orin in Force Recovery Mode + usbipd attached):
    sudo ./flash_orin_nvme.sh
EOF
