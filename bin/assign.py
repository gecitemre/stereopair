#!/usr/bin/env python3
"""Put each snapclient in its own group and point it at its channel."""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from snapctl import LEFT, RIGHT, Control, group_of  # noqa: E402


def wait_for_clients(control, timeout=30):
    deadline = time.time() + timeout
    missing = {LEFT, RIGHT}
    while time.time() < deadline:
        status = control.status()
        connected = {
            client["id"]
            for group in status["groups"]
            for client in group["clients"]
            if client["connected"]
        }
        missing = {LEFT, RIGHT} - connected
        if not missing:
            return status
        time.sleep(0.5)
    sys.exit(f"assign: clients never connected: {', '.join(sorted(missing))}")


def main():
    control = Control()
    status = wait_for_clients(control)

    left, right = group_of(status, LEFT), group_of(status, RIGHT)
    if left["id"] == right["id"]:
        # Snapcast drops the clients we leave out into a fresh group of their own.
        control.call("Group.SetClients", {"id": left["id"], "clients": [LEFT]})
        status = control.status()
        left, right = group_of(status, LEFT), group_of(status, RIGHT)

    for group, stream in ((left, "left"), (right, "right")):
        control.call("Group.SetStream", {"id": group["id"], "stream_id": stream})
        control.call("Group.SetMute", {"id": group["id"], "mute": False})
        print(f"{stream:>5} channel -> {group['clients'][0]['host']['name']}")


if __name__ == "__main__":
    main()
