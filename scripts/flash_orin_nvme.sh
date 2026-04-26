#!/usr/bin/env bash
# Flash Jetson AGX Orin 64GB Devkit to NVMe with explicit board params,
# bypassing tegrarcm EEPROM auto-detection (which fails over usbipd-win).
#
# Usage:
#   sudo ./flash_orin_nvme.sh
#
# Configuration via env vars:
#   BSP_DIR     — path to Linux_for_Tegra (default: $PWD/Linux_for_Tegra)
#   BOARDID     — module family (default: 3701, AGX Orin module)
#   BOARDSKU    — module SKU:
#                   0000 = Orin 32GB (original AGX Orin Devkit)
#                   0004 = Orin 32GB Industrial
#                   0005 = Orin 64GB Devkit  (default)
#                   0008 = Orin Industrial
#   FAB         — fab revision (default: 300, common for current devkits)
#   CHIPREV     — silicon rev (default: A02)
#   FUSELEVEL   — fuselevel_production or fuselevel_nofuse (default: production)
#
# Pre-flight checklist (the script verifies these and aborts cleanly otherwise):
#   - Orin in Force Recovery Mode, USB attached to host
#   - On Windows: usbipd attach --wsl --busid <X-Y> --auto-attach (or watcher running)
#   - WSL kernel must have RNDIS_HOST module (uname -r ends with -wsl-rndis or +)
#   - nfs-server must be active

set -euo pipefail

BSP_DIR="${BSP_DIR:-$(pwd)/Linux_for_Tegra}"

# Board params for AGX Orin 64GB Devkit (P3737 carrier + P3701-0005 module)
export BOARDID="${BOARDID:-3701}"
export BOARDSKU="${BOARDSKU:-0005}"
export FAB="${FAB:-300}"
export CHIPREV="${CHIPREV:-A02}"
export FUSELEVEL="${FUSELEVEL:-fuselevel_production}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if [[ ! -d "$BSP_DIR" ]]; then
  echo "BSP_DIR not found: $BSP_DIR" >&2
  exit 1
fi

cd "$BSP_DIR"

# ---- Pre-flight sanity ----
[[ -f rootfs/etc/nv_tegra_release ]] || { echo "rootfs not prepped — run prepare_rootfs.sh" >&2; exit 1; }
[[ -x tools/kernel_flash/l4t_initrd_flash.sh ]] || { echo "flash tool missing" >&2; exit 1; }
[[ -f tools/kernel_flash/flash_l4t_external.xml ]] || { echo "external partition layout missing" >&2; exit 1; }
[[ -f bootloader/generic/cfg/flash_t234_qspi.xml ]] || { echo "QSPI bootloader config missing" >&2; exit 1; }
lsusb | grep -q 0955:7023 || { echo "APX device 0955:7023 not visible. Re-enter FRM and re-attach via usbipd." >&2; exit 1; }
systemctl is-active --quiet nfs-server || { echo "nfs-server inactive — run: modprobe nfsd && systemctl restart nfs-server" >&2; exit 1; }

# Verify RNDIS module is available (won't be loaded yet — that happens after Phase A)
modinfo rndis_host >/dev/null 2>&1 || { echo "rndis_host kernel module not available. Build the custom kernel via build_wsl_kernel_rndis.sh." >&2; exit 1; }

LOG="flash-$(date +%Y%m%d-%H%M%S).log"

cat <<EOF
Flash starting — log: ${LOG}
BSP:           $BSP_DIR
Board params:  BOARDID=$BOARDID BOARDSKU=$BOARDSKU FAB=$FAB CHIPREV=$CHIPREV FUSELEVEL=$FUSELEVEL

Reminder: keep the usbipd watcher (PowerShell) running. The Orin will switch
USB IDs from APX (0955:7023) to RNDIS gadget (0955:7035) mid-flash, and your
watcher must re-attach within ~1s.

EOF

./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_external.xml \
    -p '-c bootloader/generic/cfg/flash_t234_qspi.xml' \
    --showlogs \
    --network usb0 \
    jetson-agx-orin-devkit external 2>&1 | tee "${LOG}"
