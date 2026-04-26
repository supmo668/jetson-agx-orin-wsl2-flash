# Runbook — Flashing Jetson AGX Orin 64 GB Devkit (JetPack 6.2 / L4T R36.4.3)

**Host:** Windows 11 + WSL2 Ubuntu 22.04 (this machine)
**Target:** Jetson AGX Orin Developer Kit, 64 GB eMMC variant
**BSP path:** `/home/mo/nvidia/Linux_for_Tegra`
**Default user baked into rootfs:** `mm` (UID 1000)
**Est. duration:** 20–40 min end-to-end

---

## 0. Pre-flight (do once, right before flashing)

Check the BSP is still prepped:

```bash
cd /home/mo/nvidia/Linux_for_Tegra
test -f rootfs/etc/nv_tegra_release && echo "rootfs OK" || echo "RE-RUN prepare_rootfs.sh"
test -x flash.sh && echo "flash.sh OK"
```

On Windows, confirm usbipd is installed:

```powershell
usbipd --version
```

### 0.5. WSL2 kernel must support RNDIS (one-time prerequisite)

The stock WSL2 kernel ships **without** `CONFIG_USB_NET_RNDIS_HOST`. The Jetson
AGX Orin's initrd flash uses RNDIS to expose `usb0` during Phase B (rootfs
copy), so without this the flash will fail with `pinging the target ip failed`.

Check:

```bash
zcat /proc/config.gz | grep -iE "RNDIS_HOST|CDC_NCM|USB_USBNET"
```

Required:
```
CONFIG_USB_USBNET=y          (or =m if modules load automatically)
CONFIG_USB_NET_RNDIS_HOST=y  (or =m)
CONFIG_USB_NET_CDC_NCM=y     (or =m)
```

If `CONFIG_USB_NET_RNDIS_HOST is not set`, build a custom kernel once:

```bash
# One-time: install kernel build deps
sudo apt-get install -y build-essential flex bison dwarves libssl-dev \
    libelf-dev bc cpio libncurses-dev python3 git

# Build RNDIS-enabled kernel (~25 min)
/home/mo/nvidia/build_wsl_kernel_rndis.sh
```

After build, the script stages `bzImage-rndis` to `C:\WSL_Kernel\`. On Windows,
edit `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
kernel=C:\\WSL_Kernel\\bzImage-rndis
```

Then in an elevated PowerShell:
```powershell
wsl --shutdown
```

Reopen WSL and re-verify with the `zcat` check above.

Target storage — **this devkit has an M.2 NVMe SSD → Option B.**
- **Option A — eMMC (internal 64 GB):** Fallback only. Use if NVMe is absent or not detected.
- **Option B — NVMe (external SSD): ← CHOSEN.** Root partition lives on the SSD. Faster I/O, more space for CUDA/TRT/models. Required path for this device.

Confirm the SSD is seated and detectable before flashing. If you have another Linux host, `lspci | grep -i nvme` on the Orin (when booted) shows it. From a fresh Orin you can't check — the `l4t_initrd_flash.sh` tool will fail loudly in Step 3 if no NVMe is found, which is safe.

---

## 1. Put the Orin into Force Recovery Mode (FRM)

> **Physical sequence matters.** If the Orin boots normally, you'll see it as `0955:7020` (boot) not `0955:7023` (APX) and flash will fail.

1. Power off the Orin completely (unplug DC barrel jack).
2. Connect a USB-C cable from the Orin's **recovery port** (front USB-C on the devkit, labeled as such) to a USB-A/USB-C port on the Windows host. **Avoid hubs.** Use the shortest cable you have.
3. Plug DC power back into the Orin. LEDs light up but there is no HDMI output — expected.
4. Press and **hold** the **FORCE RECOVERY** button.
5. While holding it, press and **release** the **RESET** button.
6. Continue holding FORCE RECOVERY for ~2 s, then release.

The Orin is now in APX mode, listening on USB. Fans may spin slowly; no boot beep; no HDMI output.

---

## 2. Attach USB to WSL (Windows side)

Open **elevated PowerShell** on Windows.

```powershell
usbipd list
```

Look for a line like:
```
BUSID   VID:PID     DEVICE
2-4     0955:7023   APX
```

Note the **BUSID** (e.g. `2-4`).

First time only — bind with `--force` (persists across reboots, overrides any prior share):
```powershell
usbipd bind --busid 2-4 --force
```

Every time you want to flash — use `--auto-attach` so the device re-binds if it
drops during mode transitions (helps prevent the empty-ECID / "Unrecognized
module SKU" error caused by stale tegrarcm sessions):
```powershell
usbipd attach --wsl --busid 2-4 --auto-attach
```

Leave the `--auto-attach` PowerShell window open for the duration of the flash.

Verify inside WSL:
```bash
lsusb | grep -iE "0955|nvidia"
# Expected: Bus 001 Device 00X: ID 0955:7023 NVIDIA Corp. APX
```

If the device doesn't appear:
- Orin may have timed out of FRM → repeat Step 1.
- `wsl --shutdown` in PowerShell, then reopen WSL and re-attach.
- `usbipd state` — status should show `Attached`.

---

## 3. Flash

> Everything below runs in WSL as root.

### Option B — NVMe flash (chosen — root on SSD)

```bash
cd /home/mo/nvidia/Linux_for_Tegra
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_external.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    --showlogs \
    --network usb0 \
    jetson-agx-orin-devkit external \
    2>&1 | tee flash-$(date +%Y%m%d-%H%M%S).log
```

What this does:
- Flashes the QSPI bootloader chain to the module.
- Brings up a transient initrd Linux on the Orin that mounts over USB networking (`usb0`, default IP 192.168.55.1 host / 192.168.55.100 target).
- From the host side, copies the full rootfs image to the NVMe (partition `nvme0n1p1`).
- Expected duration: ~20–30 min (USB network is the bottleneck).

You'll see output like `[...] pinging the target ip` during the network handshake — that's normal, don't interrupt.

### Option A — eMMC flash (fallback only)

Use this only if NVMe is not detected or you want to repurpose the devkit without an SSD.

```bash
cd /home/mo/nvidia/Linux_for_Tegra
sudo ./flash.sh jetson-agx-orin-devkit internal 2>&1 | tee flash-$(date +%Y%m%d-%H%M%S).log
```

Phases: `Generating default system.img` → `Creating Flash Configuration` → `Creating flash images` → `Flashing the board…` (~10–15 min) → `Flash complete`.

---

## 4. Do NOT touch anything during flash

- Don't unplug USB.
- Don't power-cycle the Orin.
- Don't close the WSL terminal.
- Don't let the Windows host sleep. (Set power plan to High Performance / disable sleep for the duration.)

A partial flash leaves the Orin in a bricked-but-recoverable state — you just re-enter FRM and flash again. But it wastes 15+ min.

---

## 5. Post-flash boot

On successful `Flash complete`:

1. **Detach USB** from WSL (on Windows, elevated PowerShell):
   ```powershell
   usbipd detach --busid 2-4
   ```
2. **Power-cycle the Orin:** unplug DC, remove the USB-C cable, wait 5 s, plug DC back in.
3. Connect HDMI + keyboard + mouse (and Ethernet if you want network on first boot).
4. First boot takes **2–3 minutes** — Ubuntu finalizes setup and reboots once automatically.
5. Log in as `mm` with the password you set in `prepare_rootfs.sh` (env var `JETSON_PASS`).
6. Verify L4T version on the Orin:
   ```bash
   cat /etc/nv_tegra_release
   # Expect: # R36 (release), REVISION: 4.3, ...
   head -1 /etc/nv_boot_control.conf
   ```

---

## 6. Post-install on the Orin (optional but recommended)

```bash
# Max performance mode (MAXN)
sudo nvpmodel -m 0
sudo jetson_clocks

# Install the JetPack 6.2 runtime stack (CUDA, TensorRT, cuDNN, VPI, Multimedia API, DeepStream hooks)
sudo apt update
sudo apt install nvidia-jetpack

# Verify
dpkg -l | grep -E "nvidia-jetpack|cuda|tensorrt" | head -20
nvidia-smi            # won't work on Jetson — use the below
sudo tegrastats        # live SoC stats (GPU, CPU, temp, power)
```

---

## 7. Rollback / if something goes wrong

| Symptom | Action |
|---|---|
| `flash.sh` exits non-zero, "probing failed" | Device fell out of FRM. Go to Step 1, re-attach, re-flash. |
| USB disconnects mid-flash | Replace cable (short, direct, no hub). Re-flash from Step 1. |
| Orin boots to a blank screen post-flash | Try a different HDMI cable/monitor. Check `sudo tegrastats` via serial console (`/dev/ttyUSB*` on host, 115200 baud). |
| Need to flash again cleanly | Just repeat the whole runbook — flashing is idempotent and overwrites everything. |
| `prepare_rootfs.sh` was re-run but rootfs is dirty | `sudo rm -rf rootfs/*` (keep README.txt), re-extract the rootfs tarball, re-run `prepare_rootfs.sh`. |
| Want to start from scratch | `rm -rf Linux_for_Tegra && tar xjf jetson_linux_r36.4.3_aarch64.tbz2 && ./prepare_rootfs.sh` |

---

## 8. Reference

- BSP root: `/home/mo/nvidia/Linux_for_Tegra`
- Flash log: `/home/mo/nvidia/Linux_for_Tegra/flash-*.log` (created by the tee in Step 3)
- usbipd + FRM details: `USBIPD_FLASH_GUIDE.md`
- NVIDIA L4T Quick Start (R36.4): https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/IN/QuickStart.html
- JetPack 6.2 release notes: https://developer.nvidia.com/embedded/jetson-linux-r3643
