# Flash Jetson AGX Orin from WSL2

Battle-tested scripts and a runbook for flashing the **NVIDIA Jetson AGX Orin
64GB Developer Kit** with **JetPack 6.2 (L4T R36.4.3)** from a Windows 11 host
running **WSL2 Ubuntu 22.04** — no native Linux required, no SDK Manager.

This is the working configuration that produced a successful NVMe flash after
debugging six distinct WSL2-specific failures. Every script here is the version
that ran end-to-end on real hardware; nothing is theoretical.

## Why this exists

NVIDIA's official path is "use a native Ubuntu host, or use SDK Manager". WSL2
isn't supported. But it works — once you fix:

1. **Stock WSL2 kernel lacks `CONFIG_USB_NET_RNDIS_HOST`** → Phase B (rootfs
   copy over `usb0`) fails silently. Solution: build a custom kernel with the
   module enabled.
2. **Tegra board EEPROM read fails over usbipd-win** → Phase A bails with
   `Error: Unrecognized module SKU` because all detection fields come back
   empty. Solution: pass `BOARDID/BOARDSKU/FAB/CHIPREV/FUSELEVEL` env vars to
   override auto-detect.
3. **APX → initrd USB device transition** → the Orin re-enumerates from
   `0955:7023` to `0955:7035` mid-flash. `usbipd attach --auto-attach` watches
   a `BUSID` but loses its binding when the VID/PID changes at the same busid.
   Solution: a watcher script that re-binds + attaches any 0955 device that
   appears.
4. **`nfs-kernel-server` won't start** → the initrd flash uses NFS to share
   the rootfs to the transient initrd Linux on the Orin. Stock WSL2 doesn't
   load `nfsd` automatically. Solution: explicit `modprobe nfsd`.
5. **systemd-managed rpcbind conflicts** with the script's own start attempt.
   Solution: the warning is benign — rpcbind is already running, ignore it.
6. **Secureboot package warning** for production-fused modules. Solution: the
   `# exit 1` is commented out in NVIDIA's script; the warning is non-fatal.

## What's in here

```
scripts/
  prepare_rootfs.sh           # Extract sample rootfs, apply_binaries, create user
  build_wsl_kernel_rndis.sh   # Build custom WSL2 kernel with RNDIS modules
  install_wsl_kernel.sh       # Install built kernel into Windows .wslconfig
  flash_orin_nvme.sh          # Run the NVMe flash with board-param overrides
  usbipd-orin-watch.ps1       # PowerShell watcher for APX → RNDIS busid transition

docs/
  FLASH_RUNBOOK.md            # Step-by-step manual procedure
  USBIPD_FLASH_GUIDE.md       # usbipd-win install + Force Recovery Mode reference
  TROUBLESHOOTING.md          # Each failure mode and how to recognize/fix it
```

## Hardware tested

- Host: Windows 11 + WSL2 Ubuntu 22.04 (kernel `6.6.123.2-wsl-rndis+` after the kernel rebuild)
- Target: Jetson AGX Orin Developer Kit, 64 GB variant (P3737 carrier + P3701-0005 module)
- Storage: M.2 NVMe SSD (root partition lives on NVMe, not eMMC)
- BSP: JetPack 6.2 / L4T R36.4.3

If your hardware differs, see `docs/FLASH_RUNBOOK.md` for the spots where
constants need adjusting (most importantly `BOARDSKU` for non-64GB modules,
`FAB` for older units).

## Quick start

> Read `docs/FLASH_RUNBOOK.md` before running anything. The order matters and
> some steps are gated behind one-time prerequisites (custom kernel build).

In rough order:

1. **Download the BSP and rootfs** from NVIDIA into a working dir (`~/nvidia/` or wherever).
2. **Extract the BSP**: `tar xjf jetson_linux_*.tbz2`
3. **Run `scripts/prepare_rootfs.sh`** to extract the sample rootfs, apply NVIDIA binaries, and create the default user.
4. **Build the custom WSL2 kernel** (one-time, ~25 min): `scripts/build_wsl_kernel_rndis.sh`
5. **Install the kernel into `.wslconfig`**: `scripts/install_wsl_kernel.sh`
6. **`wsl --shutdown`** in elevated PowerShell, reopen WSL.
7. **Install usbipd-win** on Windows: `winget install dorssel.usbipd-win`
8. **Start the watcher**: `powershell -ExecutionPolicy Bypass -File C:\path\to\usbipd-orin-watch.ps1`
9. **Force Recovery Mode** the Orin (REC + RST + release REC).
10. **Flash**: `sudo scripts/flash_orin_nvme.sh`

Expect ~30–45 min end-to-end on first run.

## Prerequisites

### On Windows
- Windows 11 (Windows 10 also works in theory; tested on 11)
- WSL2 with Ubuntu 22.04 distro
- usbipd-win 4.x or later (`winget install dorssel.usbipd-win`)
- Administrative PowerShell (for `usbipd bind` and the watcher)

### In WSL
- Ubuntu 22.04
- ≥ 30 GB free disk space (BSP + rootfs + kernel build + flash images)
- Sudo access (passwordless recommended for the flash session — see runbook)
- Build dependencies for kernel compile (script lists them)

### Hardware
- Jetson AGX Orin Devkit + USB-C cable + DC power supply
- M.2 NVMe SSD seated in the carrier (for NVMe flash path; eMMC fallback is documented)

## Configuration

All scripts respect `BSP_DIR` env var (default: `$PWD/Linux_for_Tegra` resolved
relative to where the script is run). Override if your BSP lives elsewhere:

```bash
export BSP_DIR=/path/to/your/Linux_for_Tegra
sudo -E scripts/flash_orin_nvme.sh
```

Board params for `flash_orin_nvme.sh` are at the top of the script, set for
AGX Orin 64GB devkit by default. Edit them if you have a different SKU.

## License

MIT. See `LICENSE`.

## Disclaimer

Flashing a Jetson is a destructive operation that overwrites the device's
storage. The procedure here worked for the author on real hardware, but you
are responsible for backing up anything important and verifying these scripts
against your own setup before running them. NVIDIA's official documentation
(linked in the runbook) is the source of truth for what the BSP expects.
