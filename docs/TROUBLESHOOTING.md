# Troubleshooting

Each entry: symptom → root cause → fix. Ordered roughly by where in the flash
sequence you'll hit them.

---

## "ECID is" / "Unrecognized module SKU" / "Board ID() version() sku()"

**Symptom:**
```
ECID is
Board ID() version() sku() revision()
Preset RAMCODE is
Chip SKU(00:00:00:D0) ramcode() fuselevel(fuselevel_production) board_FAB()
Error: Unrecognized module SKU
```

Chip SKU `D0` (= T234 Orin) was read OK, but every subsequent EEPROM read
returned empty. The conf file then errors because `""` doesn't match any known
SKU (`0000/0001/0002/0004/0005`).

**Root cause:** USB/IP latency through usbipd-win. tegrarcm's bootrom protocol
makes synchronous bulk reads with timing assumptions that the USB/IP transport
breaks under. The first read (chip ID) fits in one packet and arrives; the
follow-on reads time out.

**Fix:** Set `BOARDID/BOARDSKU/FAB/CHIPREV/FUSELEVEL` env vars to override the
auto-detect path. `flash_orin_nvme.sh` already does this with values for the
AGX Orin 64GB devkit:

```
BOARDID=3701  BOARDSKU=0005  FAB=300  CHIPREV=A02  FUSELEVEL=fuselevel_production
```

For other modules, see `BOARDSKU` reference in the script comment.

---

## "Please install the Secureboot package to use initrd flash for fused board"

**Symptom:** the line above appears, often with "fuselevel(fuselevel_production)".

**Root cause:** A check in `tools/kernel_flash/l4t_initrd_flash.sh` (~line 81)
warns when the module is fused at production level and `bootloader/odmsign.func`
is missing. The Secureboot package adds this file.

**Fix:** **None needed for non-secureboot flashing.** The `exit 1` on the next
line is **commented out**:

```bash
if ! [ -f "${BOOTLOADER_DIR}/odmsign.func" ]  && [ "${flash_only}" = "0" ]; then
    echo "Please install the Secureboot package to use initrd flash for fused board"
    # exit 1                  # <-- commented; warning is non-fatal
fi
```

The flash continues. Ignore the warning unless you actually need cryptographic
secureboot.

---

## "rpcbind: another rpcbind is already running. Aborting"

**Symptom:** Above line, followed by `A dependency job for nfs-server.service failed`.

**Root cause:** systemd already started rpcbind via socket activation. The
flash script tries to start it again from scratch and fails. The
nfs-server.service then fails because its dependency declaration thinks
rpcbind never came up.

**Fix:** Two parts.

1. **The rpcbind warning is benign.** rpcbind IS running (just not the way the
   script tried to start it). Ignore it.
2. **The nfsd module is what's actually missing.** Stock WSL2 doesn't load
   `nfsd` automatically. Load it manually:

   ```
   sudo modprobe nfsd
   sudo systemctl restart nfs-server
   ```

   Make it persistent so future flashes don't trip:

   ```
   echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf
   ```

---

## "Waiting for target to boot-up..." forever (until timeout)

**Symptom:** Phase A completes, you see `Step 3: Start the flashing process`,
then 120 lines of `Waiting for target to boot-up...` and a timeout exit.

**Root cause:** When the Orin executes `rcm-boot`, it reboots out of APX mode
(VID/PID `0955:7023`) into the initrd kernel. The initrd exposes itself as a
**new** USB gadget (`0955:7035`, RNDIS class). Even though it appears at the
**same busid** in usbipd, the binding state was tied to the old VID/PID, so
the device shows as "Not shared" and `--auto-attach` doesn't claim it.

**Fix:** Run `scripts/usbipd-orin-watch.ps1` in an elevated PowerShell window
**before** you start the flash. It polls `usbipd list` every 500 ms, binds with
`--force` and attaches any `0955:*` device that appears. This handles both the
initial APX attach and the post-rcm-boot RNDIS attach automatically.

---

## "No devices to flash" with `--flash-only`

**Symptom:** You try to use `--flash-only` to "resume" after a partial run,
and the script exits immediately with `No devices to flash`.

**Root cause:** `--flash-only` skips image generation but **still requires the
Orin in APX/RCM mode**. It's not a Phase B resume — it's "skip image gen, redo
Phase A bootloader push, then Phase B". The script's `fill_devpaths` only
detects `0955:7023` (APX), not `0955:7035` (initrd).

**Fix:** Power-cycle the Orin back to APX (Force Recovery Mode) and re-run
the full flash. There is no resume-from-initrd path in the public BSP.

---

## ARP failure / Destination Host Unreachable

**Symptom:** You can `ping 192.168.55.1` from WSL and get `Destination Host
Unreachable` even though the RNDIS interface is up.

**Root cause:** L4T R36.x uses **IPv6** for the host ↔ initrd link, not IPv4.
The Orin's initrd assigns `fe80::1` to its `usb0`; the host gets `fe80::2`.
The script `ping_device()` function uses `ping6 -c 1 fe80::1%<iface>`. The
192.168.55.x scheme was older L4T (R32.x and earlier).

**Fix:** Don't manually configure IPv4. Let the flash script's `ping_device()`
do the IPv6 assignment when it discovers the right interface. If you want to
test connectivity manually:

```
ping -6 -c 3 fe80::1%<your-rndis-iface>
```

(Find the interface with `ls /sys/class/net | grep -E 'enx|usb'`.)

---

## "Device should have booted into initrd kernel now. However, the host cannot connect to its ssh server"

**Symptom:** Above message at Phase B start.

**Root cause:** Either (a) the RNDIS interface didn't come up, or (b) it came
up but the script's match-by-`configuration` regex didn't recognize it. The
script looks for udev attribute `configuration` matching `RNDIS+L4T0.*` on
the interface's parent USB device.

**Fix:** Verify:

```
for n in /sys/class/net/*/; do
  iface=$(basename $n)
  cfg=$(cat $n/device/../configuration 2>/dev/null)
  echo "$iface: $cfg"
done
```

The Orin's RNDIS interface should report `RNDIS+L4T0`. If it does and the
script still doesn't see it, check IPv6 isn't disabled on that interface:

```
sysctl net.ipv6.conf.<iface>.disable_ipv6   # must be 0
```

---

## Custom kernel boots but no RNDIS module

**Symptom:** After installing the custom kernel and `wsl --shutdown`, `lsmod`
shows no `rndis_host`, and `modprobe rndis_host` fails with "Module not found".

**Root cause:** `make modules_install` was skipped or failed. The bzImage
points to `/lib/modules/<version>/`, but that path is empty.

**Fix:** Re-run the build script — it has a `make modules_install` step. Or
manually:

```
cd ~/wsl-kernel
sudo make modules_install
ls /lib/modules/$(make -s kernelrelease)/kernel/drivers/net/usb/
```

You should see `rndis_host.ko`, `cdc_ncm.ko`, `usbnet.ko`, `cdc_ether.ko`.

---

## sudo prompts for password during the flash

**Symptom:** Flash starts, hits a sub-shell that re-invokes sudo internally,
and prompts for password — interrupting non-interactive runs.

**Root cause:** `flash.sh` and downstream tools `sudo` themselves for
privileged operations. Even if you started the parent with sudo, child shells
may re-auth depending on `Defaults timestamp_timeout` and `Defaults !tty_tickets`.

**Fix:** Add a temporary NOPASSWD rule for your user, scoped to this WSL
distro only:

```
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/99-flash
sudo chmod 0440 /etc/sudoers.d/99-flash
```

Remove after flashing:

```
sudo rm /etc/sudoers.d/99-flash
```

---

## Flash succeeds but Orin won't boot

**Symptom:** "Flash is successful" reported, you reboot, no HDMI output, no
serial console.

**Root cause:** Several possibilities, in rough probability order:
- HDMI cable / monitor doesn't handshake (try a different combo)
- Wrong `BOARDSKU` value used → flashed wrong DTB → kernel can't bring up
  PMIC and wedges before display init
- NVMe SSD wasn't detected during flash (rootfs went somewhere else / nowhere)
- Power supply insufficient (Orin needs the 65W adapter, not generic USB-C PD)

**Diagnostic:** Connect a USB-TTL serial cable to the Orin's UART pins (J51 on
the carrier — see Jetson AGX Orin Carrier Board Specification). Set the host
to 115200/8N1. You'll see U-Boot / kernel messages and can usually figure out
what stalled.

If the wrong DTB was flashed: re-flash with the correct `BOARDSKU`. The
DTB filename in the flash log tells you what was used:

```
grep "tegra234-p3737-0000+p3701-" flash-*.log | head
# AGX Orin 64GB should reference: ...p3701-0005-nv.dtb
# If it references p3701-0000 or p3701-0004, you used the wrong SKU.
```
