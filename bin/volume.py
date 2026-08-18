#!/usr/bin/env python3
"""Set both Macs to the same level.

Loudness runs through snapcast's software mixer on both machines, so the two
sides share one gain curve and match by construction. That only holds while the
two system volumes agree, so this warns when they have drifted apart.

A trim is a persistent per-side offset in points, for when one machine is
genuinely louder than the other.
"""

import json
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from snapctl import LEFT, RIGHT, Control, client_of  # noqa: E402

TRIM_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "run", "trim.json")


def load_trims():
    try:
        with open(TRIM_FILE) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {"left": 0, "right": 0}


def save_trims(trims):
    with open(TRIM_FILE, "w") as handle:
        json.dump(trims, handle)


def system_volume_local():
    out = subprocess.run(["osascript", "-e", "output volume of (get volume settings)"],
                         capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None


def system_volume_peer():
    peer = os.environ.get("PEER")
    if not peer:
        return None
    out = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", peer,
         "osascript -e 'output volume of (get volume settings)'"],
        capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None


def set_system_volume_peer(level):
    """Both machines are MacBook Pros running the same OS, so pushing the same
    slider value gives the same gain — no need to map between volume curves."""
    peer = os.environ.get("PEER")
    if not peer:
        sys.exit("volume: PEER is not set")
    subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/stereo-vol-%r@%h:%p",
         "-o", "ControlPersist=300", peer,
         f"osascript -e 'set volume output volume {level}'"],
        capture_output=True)


def set_system_volume_local(level):
    subprocess.run(["osascript", "-e", f"set volume output volume {level}"],
                   capture_output=True)


def watch():
    """Keep both Macs at the same level, whichever one you change.

    Two things make this harder than mirroring one way. macOS quantises the
    slider to 16 steps, so a value read back is rarely the value written — hence
    comparing with a tolerance rather than for equality. And after pushing a
    change, the other side reports its old level for a moment; acting on that
    would bounce the change straight back and the two would ping-pong forever.
    So a change is followed by a short quiet period before watching resumes.
    """
    tolerance = 4       # half a step; anything smaller is quantisation noise
    settle = 1.5
    state = {"peer": None}

    reader = subprocess.Popen(
        ["ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15",
         "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/stereo-vol-%r@%h:%p",
         "-o", "ControlPersist=300", os.environ["PEER"],
         "while true; do osascript -e 'output volume of (get volume settings)'; sleep 0.4; done"],
        stdout=subprocess.PIPE, text=True, bufsize=1)

    def pump():
        for line in reader.stdout:
            line = line.strip()
            if line.isdigit():
                state["peer"] = int(line)

    threading.Thread(target=pump, daemon=True).start()

    # Start from the quieter of the two. Adopting this Mac's level instead would
    # yank the other machine up to meet it, which is a nasty surprise on speakers.
    synced = system_volume_local()
    for _ in range(20):
        if state["peer"] is not None:
            break
        time.sleep(0.1)
    if state["peer"] is not None:
        synced = min(synced, state["peer"])
    set_system_volume_local(synced)
    set_system_volume_peer(synced)
    quiet_until = time.time() + settle

    while True:
        time.sleep(0.3)
        if reader.poll() is not None:
            sys.exit("volume: lost the connection to the second Mac")
        if time.time() < quiet_until:
            continue

        local, remote = system_volume_local(), state["peer"]
        if local is None or remote is None:
            continue

        if abs(local - synced) > tolerance:      # this Mac wins if both moved
            set_system_volume_peer(local)
            synced = local
        elif abs(remote - synced) > tolerance:
            set_system_volume_local(remote)
            synced = remote
        else:
            continue
        quiet_until = time.time() + settle


def set_volume(control, status, client_id, percent):
    client = client_of(status, client_id)
    if client is None:
        sys.exit(f"volume: {client_id} is not connected")
    control.call("Client.SetVolume",
                 {"id": client_id, "volume": {"muted": False, "percent": percent}})


def main():
    args = sys.argv[1:]

    if "--watch" in args:
        watch()
        return
    if "--match" in args:
        level = system_volume_local()
        set_system_volume_peer(level)
        print(f"  peer system volume set to {level}%")
        return

    trims = load_trims()

    for flag, key in (("--trim-left", "left"), ("--trim-right", "right")):
        if flag in args:
            index = args.index(flag)
            trims[key] = int(args[index + 1])
            del args[index:index + 2]
    save_trims(trims)

    control = Control()
    status = control.status()

    if args:
        level = max(0, min(100, int(args[0])))
        for client_id, key in ((LEFT, "left"), (RIGHT, "right")):
            set_volume(control, status, client_id,
                       max(0, min(100, level + trims[key])))
        status = control.status()

    left, right = client_of(status, LEFT), client_of(status, RIGHT)
    for name, client in (("left ", left), ("right", right)):
        if client:
            volume = client["config"]["volume"]
            state = "" if client["connected"] else "  (DISCONNECTED)"
            print(f"  {name}  snapcast {volume['percent']:3}%  muted={volume['muted']}{state}")

    if trims["left"] or trims["right"]:
        print(f"  trims  left {trims['left']:+d}  right {trims['right']:+d}")

    local, peer = system_volume_local(), system_volume_peer()
    print(f"  system volume  this Mac {local}%  peer {peer}%")
    if local is not None and peer is not None and local != peer:
        print(f"  warning: system volumes differ by {abs(local - peer)} points, so the")
        print(f"           two sides will not match. Set both the same, then use this")
        print(f"           script for volume changes.")


if __name__ == "__main__":
    main()
