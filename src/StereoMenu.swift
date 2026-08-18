import AppKit

// bin/StereoMenu.app/../.. — the app lives in bin/, the scripts one level up.
let projectRoot = Bundle.main.bundleURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// GUI apps do not inherit a shell PATH, so snapserver, snapclient and python3
/// would all be missing without this.
let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

@MainActor
final class Controller: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stereoItem = NSMenuItem(title: "Stereo Sync", action: #selector(toggleStereo),
                                        keyEquivalent: "")
    private let volumeItem = NSMenuItem(title: "Volume Sync", action: #selector(toggleVolume),
                                        keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var busy = false

    override init() {
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        for item in [stereoItem, volumeItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let check = NSMenuItem(title: "Play Channel Check", action: #selector(playCheck), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        let ui = NSMenuItem(title: "Open Control UI", action: #selector(openControlUI), keyEquivalent: "")
        ui.target = self
        menu.addItem(ui)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
        refresh()
    }

    // MARK: - State

    private func isRunning(_ pidFile: String) -> Bool {
        let url = projectRoot.appendingPathComponent("run/\(pidFile)")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(pid, 0) == 0
    }

    private var stereoOn: Bool { isRunning("snapserver.pid") }
    private var volumeOn: Bool { isRunning("volume.pid") }

    private func refresh() {
        let stereo = stereoOn
        stereoItem.state = stereo ? .on : .off
        volumeItem.state = volumeOn ? .on : .off
        stereoItem.isEnabled = !busy
        volumeItem.isEnabled = !busy

        if busy {
            statusLine.title = "Working…"
        } else if stereo {
            statusLine.title = "Left: this Mac · Right: second Mac"
        } else {
            statusLine.title = "Not running"
        }

        let symbol = stereo ? "speaker.wave.2.fill" : "speaker.slash"
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                          accessibilityDescription: "Stereo Pair")
        // Always carry a text label too: if the symbol ever fails to load, an
        // image-only button is zero-width and the item is invisible rather than
        // merely ugly.
        statusItem.button?.title = "L·R"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.isVisible = true
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Running scripts

    /// Scripts take seconds (ssh, waiting for clients), so never block the menu.
    private func run(_ script: String, _ arguments: [String] = [],
                     environment extra: [String: String] = [:],
                     then completion: (() -> Void)? = nil)
    {
        busy = true
        refresh()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [projectRoot.appendingPathComponent(script).path] + arguments
        process.currentDirectoryURL = projectRoot
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            try? process.run()
            process.waitUntilExit()
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                completion?()
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleStereo() {
        // The menu owns the volume watcher, so both scripts must leave it alone.
        let environment = ["SYNC_VOLUME": "0"]
        run(stereoOn ? "stereo-stop" : "stereo-start", environment: environment)
    }

    @objc private func toggleVolume() {
        run("stereo-volume-sync", [volumeOn ? "stop" : "start"])
    }

    @objc private func playCheck() {
        let wav = projectRoot.appendingPathComponent("channel-check.wav")
        if FileManager.default.fileExists(atPath: wav.path) {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [wav.path]
            try? player.run()
        } else {
            run("bin/make-channel-check.sh") {
                let player = Process()
                player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                player.arguments = [wav.path]
                try? player.run()
            }
        }
    }

    @objc private func openControlUI() {
        NSWorkspace.shared.open(URL(string: "http://localhost:1780")!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Top-level code is nonisolated, but it does run on the main thread.
let controller = MainActor.assumeIsolated { Controller() }
app.run()
