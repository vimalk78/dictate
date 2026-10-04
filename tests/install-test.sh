#!/bin/bash
# Test install.sh on a fresh distro in a podman container — simulates a new
# user's machine with none of our dependencies.
#
# Usage: bash tests/install-test.sh [IMAGE] [MODEL]
#   IMAGE  fedora:44 (default), ubuntu:24.04, ubuntu:22.04, ...
#   MODEL  whisper model for the transcription check (default: tiny)
#
# Flow (as a non-root user, like a real install):
#   1. install.sh on the bare image must fail with a requirements list
#   2. run exactly the fix commands it printed (sudo ones as root)
#   3. install.sh again must succeed
#   4. smoke test: --help, then transcribe a speech sample through the
#      --listen TCP server (no mic needed)
#   5. uninstall.sh --purge must leave nothing behind
#
# Not covered (no desktop in a container): mic, push-to-talk keys,
# clipboard, notifications, systemd services.
set -euo pipefail

IMAGE="${1:-fedora:44}"
MODEL="${2:-tiny}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME="dictate-install-test-$$"

echo "=== install test: $IMAGE (model: $MODEL) ==="

# IPv6 off: a broken IPv6 route (DNS returns AAAA, connect hangs) made model
# downloads hang for minutes — keep network flakiness out of the results.
podman run -d --name "$NAME" --sysctl net.ipv6.conf.all.disable_ipv6=1 "$IMAGE" sleep infinity >/dev/null
# KEEP=1 leaves the container running for inspection
if [ -z "${KEEP:-}" ]; then
    trap 'podman rm -f -t 0 "$NAME" >/dev/null 2>&1 || true' EXIT
else
    echo "(KEEP=1: container $NAME will be left running)"
fi

# Copy tracked + new (untracked, not ignored) files from the working tree — no bind mount, so no SELinux relabeling
(cd "$REPO" && git ls-files -co --exclude-standard | tar -cf - -T -) \
    | podman exec -i "$NAME" bash -c 'mkdir -p /src && tar -xf - -C /src'

podman exec -i -e MODEL="$MODEL" "$NAME" bash <<'INNER'
set -uo pipefail

step() { echo ""; echo "──── $* ────"; }
fail() { echo ""; echo "FAIL: $*"; exit 1; }

# Baseline every real system has but minimal container images lack:
# user account tools (useradd, su) and current package lists.
if command -v apt-get >/dev/null; then
    apt-get update -qq >/dev/null
    PM=apt
else
    dnf install -y -q shadow-utils util-linux >/dev/null   # useradd, su
    PM=dnf
fi
groupadd -f input            # created by udev/systemd on real systems
useradd -m -s /bin/bash tester
chown -R tester /src
as_user() { su - tester -c "set -o pipefail; $1"; }

step "1. install.sh on bare system (expect: requirements list, exit 1)"
out=$(as_user "cd /src && bash install.sh" 2>&1); rc=$?
echo "$out"
[ $rc -ne 0 ] || fail "install.sh succeeded on a bare system — requirements check missed something"
echo "$out" | grep -q "To fix, run:" || fail "no fix instructions printed"

step "2. run the printed fix commands"
fixes=$(echo "$out" | sed -n '/^To fix, run:/,/^$/p' | sed '1d;/^$/d;s/^  //')
while IFS= read -r cmd; do
    cmd="${cmd%%#*}"                       # drop trailing comments
    cmd="$(echo "$cmd" | sed 's/[[:space:]]*$//')"
    [ -n "$cmd" ] || continue
    echo "\$ $cmd"
    if [[ "$cmd" == sudo\ * ]]; then
        cmd="${cmd#sudo }"
        cmd="${cmd/dnf install/dnf install -y}"
        cmd="${cmd/apt-get install/apt-get install -y}"
        DEBIAN_FRONTEND=noninteractive bash -c "$cmd" >/dev/null || fail "fix command failed: $cmd"
    else
        as_user "$cmd" || fail "fix command failed: $cmd"
    fi
done <<< "$fixes"

step "3. install.sh again (expect: success)"
# fresh login shell picks up new group membership and ~/.local/bin
as_user "cd /src && bash install.sh" </dev/null || fail "install.sh failed after applying its own fixes"

# A real desktop always has an audio server; without one, PortAudio's
# PipeWire backend has been seen to hang at startup. Run PipeWire (no devices).
uid=$(id -u tester)
mkdir -p /run/user/$uid && chown tester /run/user/$uid && chmod 700 /run/user/$uid
echo "export XDG_RUNTIME_DIR=/run/user/$uid" >> /home/tester/.bashrc
as_user "nohup pipewire > /tmp/pipewire.log 2>&1 &"
sleep 2

step "4a. smoke: dictate --help (x5)"
for i in 1 2 3 4 5; do
    as_user "timeout 60 dictate --help >/dev/null" || fail "dictate --help failed or hung (run $i)"
done
echo "ok"

step "4b. smoke: transcribe a speech sample via --listen server"
as_user "nohup timeout 600 dictate --serve --listen 127.0.0.1:5555 --model $MODEL > /tmp/server.log 2>&1 &"
for i in $(seq 1 180); do
    grep -q "listening on" /tmp/server.log 2>/dev/null && break
    sleep 1
done
grep -q "listening on" /tmp/server.log || { cat /tmp/server.log; fail "TCP server did not start"; }

cat > /tmp/client.py <<'PY'
# os._exit everywhere: sounddevice's PortAudio thread can keep the
# interpreter alive after an exception when no audio server is running.
import faulthandler, os, traceback
faulthandler.dump_traceback_later(240, exit=True)   # show where it hangs
try:
    import importlib.machinery, importlib.util, urllib.request
    import av, numpy as np
    path = os.path.expanduser("~/.local/share/dictate/dictate.py")
    loader = importlib.machinery.SourceFileLoader("dictate", path)
    spec = importlib.util.spec_from_loader("dictate", loader)
    dictate = importlib.util.module_from_spec(spec)
    loader.exec_module(dictate)
    urllib.request.urlretrieve("https://cdn-media.huggingface.co/speech_samples/sample1.flac", "/tmp/sample.flac")
    # Decode with PyAV directly (faster_whisper.decode_audio breaks on newer av)
    resampler = av.AudioResampler(format="s16", layout="mono", rate=16000)
    chunks = []
    with av.open("/tmp/sample.flac") as container:
        for frame in container.decode(audio=0):
            chunks += [f.to_ndarray() for f in resampler.resample(frame)]
    chunks += [f.to_ndarray() for f in resampler.resample(None)]
    audio = np.concatenate(chunks, axis=1).flatten().astype(np.float32) / 32768.0
    text = dictate.transcribe_remote(("127.0.0.1", 5555), audio, "en", None)
    print(f"transcript: {text!r}", flush=True)
    os._exit(0 if len(text.split()) >= 5 else 1)
except BaseException:
    traceback.print_exc()
    os._exit(1)
PY
chmod 644 /tmp/client.py
as_user "timeout 300 ~/.local/share/dictate/venv/bin/python /tmp/client.py" || { cat /tmp/server.log; fail "transcription failed"; }

step "5. uninstall.sh --purge (expect: nothing left behind)"
as_user "cd /src && bash uninstall.sh --purge" </dev/null || fail "uninstall.sh failed"
left=$(as_user 'ls -d ~/.local/bin/dictate ~/.local/bin/dictate-editor ~/.local/share/dictate \
    ~/.config/dictate ~/.config/systemd/user/dictate*.service ~/.claude/commands/dictate.md \
    ~/.cache/huggingface/hub/models--*faster-whisper* 2>/dev/null')
[ -z "$left" ] || fail "left behind after uninstall: $left"
echo "ok: nothing left"

echo ""
echo "PASS"
INNER
