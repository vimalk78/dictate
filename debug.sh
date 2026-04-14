#!/bin/bash
# Quick diagnostic for dictate issues.
set -e

echo "=== Services ==="
systemctl --user status dictate.service --no-pager 2>&1 | head -5
systemctl --user status dictate-ptt.service --no-pager 2>&1 | head -5

echo ""
echo "=== Socket ==="
ls -la ~/.local/share/dictate/dictate.sock 2>&1 || echo "Socket missing — daemon not running?"

echo ""
echo "=== Audio devices ==="
~/.local/share/dictate/venv/bin/python3 -c "
import sounddevice as sd
for i, d in enumerate(sd.query_devices()):
    if d['max_input_channels'] > 0:
        print(f'  {i}: {d[\"name\"]} (inputs={d[\"max_input_channels\"]})')
"

echo ""
echo "=== Mic test (2s recording) ==="
TMPFILE=$(mktemp /tmp/dictate-debug-XXXX.raw)
timeout 2 pw-record --channels 1 --rate 16000 --format f32 "$TMPFILE" 2>/dev/null || true
~/.local/share/dictate/venv/bin/python3 -c "
import numpy as np
d = np.fromfile('$TMPFILE', dtype=np.float32)
rms = np.sqrt(np.mean(d**2)) if len(d) > 0 else 0
print(f'  samples={len(d)}, rms={rms:.6f}')
if rms < 0.0001:
    print('  ⚠ Mic returning silence — try unplugging and re-plugging USB mic')
elif rms > 0.03:
    print('  ⚠ High ambient noise — audio device may be switching')
else:
    print('  ✓ Mic working')
"
rm -f "$TMPFILE"

echo ""
echo "=== PipeWire default source ==="
wpctl status 2>&1 | grep -A5 "Audio/Source" | head -8
wpctl get-volume @DEFAULT_SOURCE@ 2>&1
pactl get-source-mute @DEFAULT_SOURCE@ 2>&1

echo ""
echo "=== Keyboards (evdev) ==="
~/.local/share/dictate/venv/bin/python3 -c "
import evdev
for path in sorted(evdev.list_devices()):
    d = evdev.InputDevice(path)
    caps = d.capabilities(verbose=True)
    keys = [k for k, _ in caps.get(('EV_KEY', 1), [])]
    if 'KEY_A' in keys:
        print(f'  {path}: {d.name}')
" 2>/dev/null || echo "  evdev not available or no permission (need input group)"

echo ""
echo "=== Clipboard processes ==="
XSEL_COUNT=$(pgrep -c xsel 2>/dev/null) || XSEL_COUNT=0
WL_COUNT=$(pgrep -c wl-copy 2>/dev/null) || WL_COUNT=0
if [ "$WL_COUNT" -gt 0 ]; then
    echo "  ⚠ $WL_COUNT stale wl-copy processes (should be 0 — dictate uses xsel now)"
    ps -o pid,etime,args -C wl-copy 2>/dev/null | sed 's/^/      /'
    echo "  Fix: pkill wl-copy"
fi
if [ "$XSEL_COUNT" -le 1 ]; then
    echo "  ✓ $XSEL_COUNT xsel running (normal)"
else
    echo "  ⚠ $XSEL_COUNT xsel processes — stale processes may be blocking clipboard"
    ps -o pid,etime,args -C xsel 2>/dev/null | sed 's/^/      /'
    echo "  Fix: pkill xsel"
fi

echo ""
echo "=== Recent logs (daemon) ==="
journalctl --user -u dictate.service --no-pager -n 10

echo ""
echo "=== Recent logs (ptt) ==="
journalctl --user -u dictate-ptt.service --no-pager -n 10
