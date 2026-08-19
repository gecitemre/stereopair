#!/usr/bin/env python3
"""Keep both Macs at the same level.

Both machines run the same OS on the same hardware, so the same slider value is
the same gain and no curve mapping is involved. Volume is the system volume on
each machine; there is no software mixer in the audio path.
"""

import os
import subprocess
import sys
import threading
import time

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

    def start_reader():
        """Stream the other Mac's level over one persistent ssh session, rather
        than paying for a new connection on every poll."""
        process = subprocess.Popen(
            ["ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15",
             "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/stereo-vol-%r@%h:%p",
             "-o", "ControlPersist=300", os.environ["PEER"],
             # Loop on osascript's exit status rather than `while true`: when
             # this ssh session dies, the write fails and the loop ends. With
             # `while true` the remote loop outlives every disconnect and they
             # pile up on the other Mac, one per reconnect.
             "while osascript -e 'output volume of (get volume settings)'; do sleep 0.4; done"],
            stdout=subprocess.PIPE, text=True, bufsize=1)

        def pump():
            for line in process.stdout:
                line = line.strip()
                if line.isdigit():
                    state["peer"] = int(line)

        threading.Thread(target=pump, daemon=True).start()
        return process

    reader = start_reader()

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

        # The other Mac sleeping, or Wi-Fi dropping, kills the ssh session.
        # Reconnect rather than exiting: this is meant to be left running.
        if reader.poll() is not None:
            state["peer"] = None
            time.sleep(2)
            reader = start_reader()
            quiet_until = time.time() + settle
            continue

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

    if args:
        level = max(0, min(100, int(args[0])))
        set_system_volume_local(level)
        set_system_volume_peer(level)

    local, peer = system_volume_local(), system_volume_peer()
    print(f"  system volume  this Mac {local}%  peer {peer}%")
    if local is not None and peer is not None and local != peer:
        print(f"  warning: system volumes differ by {abs(local - peer)} points, so the")
        print(f"           two sides will not match. Set both the same, then use this")
        print(f"           script for volume changes.")


if __name__ == "__main__":
    main()
