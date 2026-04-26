#!/usr/bin/env bash
# Install or update the WSL2 kernel=… entry in C:\Users\<user>\.wslconfig
# to point at the freshly built RNDIS-enabled kernel.
#
# Idempotent: adds [wsl2] section if missing, sets/replaces kernel= line,
# preserves all other entries. Always makes a .bak before editing.
#
# After running, do:  wsl --shutdown  (from elevated PowerShell on Windows)

set -euo pipefail

WIN_KERNEL_PATH='C:\\WSL_Kernel\\bzImage-rndis'
BZIMAGE_WSL_PATH='/mnt/c/WSL_Kernel/bzImage-rndis'

# Resolve Windows %USERPROFILE% and convert to a WSL path.
winprof="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
if [[ -z "$winprof" ]]; then
  echo "Could not determine Windows USERPROFILE via cmd.exe" >&2
  exit 1
fi
# e.g. C:\Users\mo  ->  /mnt/c/Users/mo
wsl_prof="$(printf '/mnt/%s' "$(echo "$winprof" | sed -E 's|^([A-Za-z]):|\L\1|; s|\\|/|g')")"
cfg="${wsl_prof}/.wslconfig"

echo "Windows user profile : $winprof"
echo "WSL view of profile  : $wsl_prof"
echo "Target .wslconfig    : $cfg"

# Sanity: confirm the bzImage actually exists before we point WSL at it.
if [[ ! -f "$BZIMAGE_WSL_PATH" ]]; then
  echo "ERROR: $BZIMAGE_WSL_PATH not found. Run build_wsl_kernel_rndis.sh first." >&2
  exit 1
fi
echo "bzImage present      : $(ls -lh "$BZIMAGE_WSL_PATH" | awk '{print $5, $9}')"

# Back up existing config if present.
if [[ -f "$cfg" ]]; then
  cp -v "$cfg" "${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
else
  : > "$cfg"
fi

python3 - "$cfg" "$WIN_KERNEL_PATH" <<'PY'
import pathlib, re, sys
cfg_path = pathlib.Path(sys.argv[1])
kernel_val = sys.argv[2]
text = cfg_path.read_text() if cfg_path.exists() else ""

# Split into [section] blocks
# We target the [wsl2] block; create it if missing; set kernel= inside it.
blocks = re.split(r'(?m)^(?=\[)', text)
out_blocks = []
wsl2_found = False
for b in blocks:
    if b.startswith('[wsl2]'):
        wsl2_found = True
        if re.search(r'(?m)^\s*kernel\s*=', b):
            b = re.sub(r'(?m)^\s*kernel\s*=.*$', f'kernel={kernel_val}', b, count=1)
        else:
            if not b.endswith('\n'):
                b += '\n'
            b += f'kernel={kernel_val}\n'
    out_blocks.append(b)
if not wsl2_found:
    suffix = '\n' if (out_blocks and not out_blocks[-1].endswith('\n')) else ''
    out_blocks.append(f'{suffix}[wsl2]\nkernel={kernel_val}\n')

cfg_path.write_text(''.join(out_blocks))
print(f"Wrote {cfg_path}")
PY

echo
echo "=== resulting $cfg ==="
cat "$cfg"
echo "======================="
echo
echo "Next — from an elevated PowerShell on Windows:"
echo "    wsl --shutdown"
echo
echo "Then reopen WSL and verify:"
echo "    uname -r                # should end with -wsl-rndis"
echo "    sudo modprobe rndis_host && lsmod | grep -E 'rndis|cdc_ncm|usbnet'"
