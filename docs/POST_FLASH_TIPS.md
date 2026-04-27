# Post-flash tips and the snap/SELinux fix design

## Why your post-flash Jetson can't run snaps

L4T's flash pipeline does not preserve **extended attributes (xattrs)** end-to-end.
File capabilities — like the `cap_dac_override` that `/usr/lib/snapd/snap-confine`
needs to launch confined snaps — are stored as `security.capability` xattrs.
When tar extraction or image build doesn't ask for `--xattrs`, the cap bits
get silently dropped.

Symptoms you'll see on a freshly flashed Jetson with stock instructions:

- `snap install <anything>` works but `snap run <thing>` fails with:
  ```
  cannot locate "matchpathcon" executable
  snap-confine is packaged without necessary permission
  required permitted capability cap_dac_override not found
  ```
- The SELinux warning is a **red herring** — it's a probe-and-warn, not the
  cause. The cap line is the real failure.
- GNOME Software 41.5 silently fails for the same snaps.
- Boot can stall briefly while systemd waits on a failing `snap-*.mount` unit.

## The three-layer fix in this repo

`prepare_rootfs.sh` defends the rootfs at three points so this can't recur:

### Layer 1 — Preserve xattrs during tarball extract

```bash
tar --xattrs --xattrs-include='*' -xpf <sample-rootfs>.tbz2
```

Without `--xattrs`, the `security.capability` xattr on snap-confine (and on
ping, mtr, etc.) is silently dropped by the host's tar even if the upstream
tarball had it. With it, anything the upstream tarball captured carries
through to your flashed image.

### Layer 2 — chroot into the prepared rootfs and reinstall snapd

After `apply_binaries.sh` and `l4t_create_default_user.sh`, the script enters
the rootfs via `qemu-aarch64-static` and runs:

```bash
apt-get install --reinstall snapd
```

snapd's `postinst` hook calls `setcap` on `/usr/lib/snapd/snap-confine`. The
caps go directly into ext4-backed xattrs that the L4T image build does
preserve, so they survive into the flashed system.

If qemu-user-static isn't on the host, this layer is skipped — the script
prints a warning and Layer 3 takes over.

### Layer 3 — jetson-firstboot self-heal at first boot

`jetson-firstboot.service` runs once on first boot, AFTER `snapd.service`.
It:

1. Loads `squashfs` and `loop` kernel modules (some snap mounts need them
   and they're not always auto-loaded on fresh L4T installs).
2. Verifies file capabilities on `snap-confine`. If missing:
   - Reinstalls snapd
   - Falls back to explicit `setcap` if reinstall didn't help
3. Restarts any `snap-*.mount` units that failed during early boot.
4. Marks itself complete (`/var/lib/jetson-firstboot.done`) and disables
   itself so it never runs again.
5. Logs to `/var/log/jetson-firstboot.log` so you can audit afterward.

This is the safety net. If Layers 1 and 2 worked perfectly, Layer 3 is a
no-op (its check finds caps present and exits). If something slipped — say
a future L4T release introduces a new image-build step that strips xattrs
again — Layer 3 catches it.

## Other post-flash issues this repo doesn't fix yet

These are still on you. Recipes in TROUBLESHOOTING.md or below.

### GNOME Software 41.5 shows phantom-installed apps

The Software app on Ubuntu Jammy aggregates from multiple plugin backends,
each registered as a "source": Ubuntu apt, Snap Store, NVIDIA L4T apt, plus
sometimes Flathub and fwupd — that's how you end up with 4–5 sources.

When a snap install fails (which happens on Jetson before the cap fix),
gnome-software 41 marks it as installed anyway. Then "Open" does nothing.

```bash
# Reset cached state
pkill -f gnome-software
rm -rf ~/.cache/gnome-software ~/.local/share/gnome-software

# Drop the snap plugin so Software stops trying to manage snaps it can't launch
sudo apt remove --purge gnome-software-plugin-snap
```

After that, Software shows only apt-managed apps — same scope as `apt`, no
phantom installs.

### Firefox snap doesn't render on Tegra GPU

Ubuntu 22.04 ships Firefox as a snap. The snap's confined sandbox can't
reach NVIDIA's L4T GPU driver stack, so it fails at WebRender init.

```bash
sudo snap remove --purge firefox
sudo add-apt-repository ppa:mozillateam/ppa -y
sudo tee /etc/apt/preferences.d/mozilla-firefox > /dev/null <<'EOF'
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF
sudo apt update
sudo apt install -y firefox
```

This is the standard "deb instead of snap" Firefox recipe — well-known on
Ubuntu desktop, works on Jetson because the deb uses native NVIDIA libs
instead of the sandbox.

### Brave on aarch64

Brave's official apt repo is **x86_64 only** as of writing. On aarch64
Jetson, snap is the only first-party route. With Layer 1+2+3 fixes from
this repo, `sudo snap install brave` should work on a fresh flash.

If snap is still painful, fall back to Vivaldi (official aarch64 deb at
https://vivaldi.com/download/) or use Chromium / Firefox.

### Set max performance mode and JetPack runtime

```bash
sudo apt update
sudo apt install -y nvidia-jetpack
sudo nvpmodel -m 0       # MAXN
sudo jetson_clocks
sudo tegrastats           # live SoC stats — Ctrl+C to stop
```

## Verification checklist after first boot

```bash
# Layer 3 ran?
cat /var/lib/jetson-firstboot.done            # should print a timestamp
cat /var/log/jetson-firstboot.log | tail -30  # should show "complete"

# Caps present?
getcap /usr/lib/snapd/snap-confine
# Expect: cap_audit_write,cap_dac_override,...=ep

# Snap mounts healthy?
systemctl --failed
# Expect: 0 loaded units listed

# Snap install actually works end-to-end?
sudo snap install hello-world
hello-world
# Expect: "Hello World!" — confirms snap-confine path works
```

If all four pass, snap is operational. Then `sudo snap install brave` should
go through cleanly.
