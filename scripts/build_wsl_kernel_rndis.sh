#!/usr/bin/env bash
# Build a WSL2 kernel with RNDIS + CDC host drivers as loadable modules,
# then install those modules into /lib/modules so the new kernel can load them.
#
# Why modules and not built-in: stock WSL2 config has CONFIG_USB=m at the root,
# which forces every child (USB_USBNET, USB_NET_RNDIS_HOST, CDC_*) to =m. Can't
# promote to =y without rewriting the whole USB subtree.
#
# Prereqs (run once, separately):
#   sudo apt-get install -y build-essential flex bison dwarves libssl-dev \
#       libelf-dev bc cpio libncurses-dev python3 git kmod
#
# Usage:  ./build_wsl_kernel_rndis.sh
# Requires sudo for the final `make modules_install` step (prompts).
# Output:
#   /mnt/c/WSL_Kernel/bzImage-rndis
#   /lib/modules/<new-release>/kernel/drivers/net/usb/{rndis_host,cdc_ncm,...}.ko

set -euo pipefail

SRC_DIR="${HOME}/wsl-kernel"
OUT_DIR="/mnt/c/WSL_Kernel"
OUT_FILE="${OUT_DIR}/bzImage-rndis"
BRANCH="linux-msft-wsl-6.6.y"
LOCALVERSION="-wsl-rndis"

echo "[1/8] Checking build dependencies…"
missing=()
for pkg in gcc flex bison make bc cpio git; do
  command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} > 0 )); then
  echo "Missing: ${missing[*]}" >&2
  echo "Run: sudo apt-get install -y build-essential flex bison dwarves libssl-dev libelf-dev bc cpio libncurses-dev python3 git kmod" >&2
  exit 1
fi

echo "[2/8] Cloning / updating Microsoft WSL2 kernel source ($BRANCH)…"
if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" fetch --depth=1 origin "$BRANCH"
  git -C "$SRC_DIR" checkout "$BRANCH"
  git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
else
  git clone --depth 1 --branch "$BRANCH" https://github.com/microsoft/WSL2-Linux-Kernel.git "$SRC_DIR"
fi
cd "$SRC_DIR"

echo "[3/8] Seeding .config from running kernel…"
zcat /proc/config.gz > .config

echo "[4/8] Enabling USB network host drivers as modules…"
./scripts/config --module CONFIG_USB
./scripts/config --module CONFIG_USB_USBNET
./scripts/config --module CONFIG_USB_NET_RNDIS_HOST
./scripts/config --module CONFIG_USB_NET_CDC_ETHER
./scripts/config --module CONFIG_USB_NET_CDC_NCM
./scripts/config --module CONFIG_USB_NET_CDC_EEM
./scripts/config --module CONFIG_USB_NET_CDC_SUBSET
./scripts/config --module CONFIG_USB_NET_MII
# Identifier so we can tell the custom kernel apart from stock in `uname -r`
./scripts/config --set-str CONFIG_LOCALVERSION "$LOCALVERSION"
./scripts/config --disable CONFIG_LOCALVERSION_AUTO
# Suppress the "+" dirty-tree suffix that scripts/setlocalversion appends when
# the git tree has any modifications. An empty .scmversion makes it skip the
# git-state probe entirely — release string becomes deterministic.
: > .scmversion
# Accept upstream defaults for any new prompts introduced by the branch's patchlevel.
# `make olddefconfig` is non-interactive by design — don't pipe `yes` into it
# (SIGPIPE vs pipefail caused silent exits on a prior run).
make olddefconfig </dev/null >/dev/null

echo "      Verifying config edits:"
grep -E "^CONFIG_USB_NET_RNDIS_HOST=|^CONFIG_USB_NET_CDC_NCM=|^CONFIG_USB_USBNET=|^CONFIG_LOCALVERSION=" .config

echo "[5/8] Building bzImage + modules — ~20–35 min on $(nproc) cores…"
time make -j"$(nproc)" bzImage modules

# Compute KERNELRELEASE AFTER the build — only then is include/config/auto.conf
# fully populated with the effective LOCALVERSION. Querying it earlier returns
# the stale stock value and mis-points downstream depmod / modules_install.
KRELEASE="$(make -s kernelrelease)"
echo "      Built KERNELRELEASE: $KRELEASE"

echo "[6/8] Installing modules to /lib/modules/$KRELEASE (needs sudo)…"
sudo make modules_install

echo "[7/8] Regenerating module dependency index for the new kernel…"
# make modules_install typically runs depmod internally; re-run defensively,
# and fall back to bare `depmod -a` if the targeted release isn't found.
sudo depmod -a "$KRELEASE" || sudo depmod -a

echo "[8/8] Staging bzImage to Windows filesystem at $OUT_FILE …"
mkdir -p "$OUT_DIR"
cp arch/x86/boot/bzImage "$OUT_FILE"
sha256sum "$OUT_FILE"

cat <<EOF

=============================================================================
Build complete.

Kernel:    $OUT_FILE
Release:   $KRELEASE
Modules:   /lib/modules/$KRELEASE/kernel/drivers/net/usb/

Next steps (Windows side):

1. Create or edit  %USERPROFILE%\\.wslconfig  and set:

       [wsl2]
       kernel=C:\\\\WSL_Kernel\\\\bzImage-rndis

   (double backslashes required in .wslconfig).

2. In an elevated PowerShell:

       wsl --shutdown

3. Reopen WSL and verify inside WSL:

       uname -r       # expect: $KRELEASE
       sudo modprobe rndis_host && lsmod | grep rndis_host
       # expect: rndis_host ... cdc_ether ... usbnet ...

4. Put the Orin back in Force Recovery Mode, re-attach via usbipd with
   --force and --auto-attach, then rerun the NVMe flash command from
   FLASH_RUNBOOK.md §3.
EOF
