"""Minimal snapcast JSON-RPC client shared by the helper scripts."""

import json
import socket

CONTROL = ("127.0.0.1", 1705)
LEFT, RIGHT = "stereo-left", "stereo-right"


class Control:
    def __init__(self):
        self.sock = socket.create_connection(CONTROL, timeout=5)
        self.buffer = b""
        self.counter = 0

    def call(self, method, params=None):
        self.counter += 1
        request = {"jsonrpc": "2.0", "id": self.counter, "method": method}
        if params:
            request["params"] = params
        self.sock.sendall((json.dumps(request) + "\r\n").encode())
        while True:
            message = json.loads(self._readline())
            if message.get("id") != self.counter:
                continue  # notification
            if "error" in message:
                raise RuntimeError(f"{method}: {message['error']}")
            return message["result"]

    def _readline(self):
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("control connection closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def status(self):
        return self.call("Server.GetStatus")["server"]


def group_of(status, client_id):
    for group in status["groups"]:
        if any(client["id"] == client_id for client in group["clients"]):
            return group
    return None


def client_of(status, client_id):
    for group in status["groups"]:
        for client in group["clients"]:
            if client["id"] == client_id:
                return client
    return None
