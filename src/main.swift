// Entry point. Top-level code has to live in main.swift once the target has
// more than one file.

import Darwin
import Foundation

// MARK: - Entry

var mode = ""
var host = ""
var port: UInt16 = 4711
var targetMs = 0   // 0 = decide from the link
var ioFrames: UInt32 = 128
var peerName: String?

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--recv": mode = "recv"
    case "--selftest": mode = "selftest"
    case "--send":
        mode = "send"
        // Optional: with no address, or "auto", the receiver is found over Bonjour.
        if let value = args.first, !value.hasPrefix("--") {
            args.removeFirst()
            host = value
        }
    case "--peer-name":
        peerName = args.removeFirst()
    case "--list":
        mode = "list"
    case "--port": port = UInt16(args.removeFirst()) ?? 4711
    case "--target-ms":
        let value = args.removeFirst()
        targetMs = value == "auto" ? 0 : (Int(value) ?? 0)
    case "--io-frames": ioFrames = UInt32(args.removeFirst()) ?? 128
    case "--debug-tap":
        tapLayoutReports = 3
    case "--log":
        // Launched via `open`, so stderr has nowhere to go.
        freopen(args.removeFirst(), "a", stderr)
    default: die("unknown argument \(arg)")
    }
}

signal(SIGPIPE, SIG_IGN)

switch mode {
case "send": runSender(host: host, port: port, targetMs: targetMs, ioFrames: ioFrames, peerName: peerName)
case "recv": runReceiver(port: port, targetMs: targetMs > 0 ? targetMs : 150, ioFrames: ioFrames)
case "selftest": runSelfTest(seconds: 3)
case "list": runList()
case "":
    // Double-clicked, or launched by launchd: this is the app.
    runMenuBarApp()
default: die("need --send [host], --recv, or --list")
}
