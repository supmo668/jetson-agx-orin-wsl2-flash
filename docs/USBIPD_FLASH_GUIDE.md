# Flashing Jetson AGX Orin 64GB Devkit via WSL2 + usbipd-win

Target: Jetson AGX Orin Developer Kit (64 GB), JetPack 6.2 (L4T R36.4.3)
Host: Windows 11 + WSL2 Ubuntu 22.04 (this box)

## One-time setup on Windows

Run in an **elevated PowerShell**:

```powershell
# Install usbipd-win
winget install --interactive --exact dorssel.usbipd-win

# Reboot Windows after install, then:
usbipd --version
```

Install `usbip` inside WSL (already pulled in by newer `linux-tools-generic`, but just in case):

```bash
sudo apt-get install -y linux-tools-virtual hwdata
sudo update-alternatives --install /usr/local/bin/usbip usbip "$(ls /usr/lib/linux-tools/*/usbip | tail -n1)" 20
```

## Put the Orin into Force Recovery Mode (FRM)

1. Power off the Orin.
2. Connect a USB-C cable from the Orin's **front USB-C port** (the one labeled as the recovery/flash port on the carrier — it is next to the 40-pin header) to a USB port on the Windows host.
3. Press and hold the **REC** (Force Recovery) button.
4. While holding REC, press and release the **RST** button.
5. Release REC.
6. LEDs should indicate power but the device will NOT boot to Linux — it sits in APX/recovery mode.

## Attach the APX device to WSL

In an **elevated PowerShell** on Windows:

```powershell
usbipd list
# Look for a device with VID:PID 0955:7023 (NVIDIA APX) — note its BUSID, e.g. 2-4
```

First time only — bind the device so WSL can claim it:

```powershell
usbipd bind --busid 2-4
```

Each flashing session — attach to WSL (must be re-run if you reboot WSL or unplug):

```powershell
usbipd attach --wsl --busid 2-4
```

Verify inside WSL:

```bash
lsusb | grep -i nvidia
# Expected: Bus 001 Device 002: ID 0955:7023 NVIDIA Corp. APX
```

If nothing shows up:
- Confirm the Orin is in FRM (a boot-mode device won't appear as 0955:7023).
- `usbipd state` on Windows should show `Attached`.
- Try `wsl.exe --shutdown` then restart WSL, rebind, reattach.

## Flash the device (after BSP prep is done)

Once `Linux_for_Tegra/rootfs/` is populated and `apply_binaries.sh` has run:

```bash
cd /home/mo/nvidia/Linux_for_Tegra
# Default: flash eMMC / internal storage
sudo ./flash.sh jetson-agx-orin-devkit internal

# Or flash to NVMe if an NVMe is present and you want root on NVMe:
# sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
#   -c tools/kernel_flash/flash_l4t_external.xml \
#   --showlogs --network usb0 jetson-agx-orin-devkit external
```

Expected duration: 10–25 minutes depending on USB speed. Do NOT unplug or release the device before flash completes — a failed flash leaves the Orin stuck in recovery.

## Detach after flashing

On Windows:

```powershell
usbipd detach --busid 2-4
```

Then on the Orin: power-cycle (unplug power, remove USB-C, plug power back in). First boot runs some setup and reboots — be patient, it may take 2–3 minutes.

## Troubleshooting

- **"Error: probing the target board failed"** → device not in FRM, or not attached to WSL. Re-do REC+RST, re-attach in PowerShell.
- **`flash.sh: command not found`** → run from `Linux_for_Tegra/` directory.
- **USB disconnects mid-flash** → known issue with some USB-C cables / hubs. Use a short direct USB-C → USB-A cable and plug directly to the PC, not through a hub.
- **WSL2 doesn't see device even after `usbipd attach`** → `wsl --update` on Windows, then `wsl --shutdown`, reattach.
- **Filesystem errors during apply_binaries/extraction** → WSL2's default drvfs mount is slow and case-insensitive. Ensure you are on the ext4 disk (e.g. `/home/mo/nvidia`), NOT on `/mnt/c/...`.

## Reference

- usbipd-win: https://github.com/dorssel/usbipd-win
- JetPack 6.2 release notes: https://developer.nvidia.com/embedded/jetson-linux-r3643
- L4T Quick Start: https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/IN/QuickStart.html
