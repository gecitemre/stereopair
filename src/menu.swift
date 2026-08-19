// The app itself: a menu bar item that finds the other Mac and sends to it.
// Everything the user touches lives here — no scripts, no ssh, no addresses.
//
// The audio work runs in child processes of this same binary (--recv, --send).
// They are children of the app bundle, so they inherit its identity and its
// audio and local-network permissions, which a bare binary would not have.

import AppKit
import ServiceManagement

@MainActor
final class Menu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sendMenu = NSMenu()
    private let sendItem = NSMenuItem(title: "Play On", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop", action: #selector(stopSending), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin),
                                       keyEquivalent: "")

    private var receiver: Process?
    private var sender: Process?
    private let discovery = LiveDiscovery()
    private var peers: [Peer] = []
    private var sendingTo: String?
    private var sentTo: String?

    private var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/stereopair")
    }

    /// Children write here rather than to a discarded stderr: without it there
    /// is no way to tell a working pair from a silently broken one, or to see
    /// the buffer drifting.
    private func logPath(_ role: String) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/StereoPair")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(role).log").path
    }

    override init() {
        super.init()

        let menu = NSMenu()
        menu.delegate = self

        sendItem.submenu = sendMenu
        menu.addItem(sendItem)
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self

        statusItem.menu = menu

        // Always listen, so the other Mac can start the pair from its side too.
        startReceiver()
        discovery.start()
        refreshPeers()
        refresh()
    }

    // MARK: - Child processes

    private func spawn(_ arguments: [String]) -> Process? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    private func startReceiver() {
        guard receiver == nil || receiver?.isRunning == false else { return }
        receiver = spawn(["--recv", "--log", logPath("receiver")])
    }

    @objc private func stopSending() {
        // SIGUSR1 rather than terminate: the sender keeps its audio tap alive
        // between sessions. Creating one per session is what wedges coreaudiod
        // until it is killed, and a stopped tap mutes nothing.
        if let process = sender, process.isRunning {
            kill(process.processIdentifier, SIGUSR1)
        }
        sendingTo = nil
        startReceiver()
        refresh()
    }

    @objc private func sendToPeer(_ item: NSMenuItem) {
        guard let peer = peers.first(where: { $0.name == item.title }) else { return }
        sendingTo = peer.name

        // Reuse a sender already pointed at this Mac: it holds the audio tap,
        // and creating a tap per session is what wedges coreaudiod.
        if let process = sender, process.isRunning, sentTo == peer.name {
            kill(process.processIdentifier, SIGUSR2)
            refresh()
            return
        }

        sender?.terminate()
        // Sending and receiving at once would fight over this Mac's speakers.
        receiver?.terminate()
        receiver = nil

        // Name, not address: choosing one here would skip the sender's own
        // check that the address it connected on actually leaves through the
        // Thunderbolt bridge.
        sender = spawn(["--send", "auto", "--peer-name", peer.name,
                        "--target-ms", "auto", "--log", logPath("sender")])
        sentTo = peer.name
        refresh()
    }

    // MARK: - State

    private func refreshPeers() {
        peers = discovery.peers
        rebuildSendMenu()
    }

    private func rebuildSendMenu() {
        sendMenu.removeAllItems()
        if peers.isEmpty {
            let empty = NSMenuItem(title: "No other Mac found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sendMenu.addItem(empty)
            return
        }
        for peer in peers {
            let item = NSMenuItem(title: peer.name, action: #selector(sendToPeer(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = peer.name == sendingTo ? .on : .off
            sendMenu.addItem(item)
        }
    }

    private var isSending: Bool { sender?.isRunning == true && sendingTo != nil }

    private func refresh() {
        if isSending, let name = sendingTo {
            statusLine.title = "Left: this Mac · Right: \(name)"
        } else {
            statusLine.title = "Ready — waiting for the other Mac"
        }
        stopItem.isEnabled = isSending
        sendItem.isEnabled = !isSending

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let symbol = isSending ? "speaker.wave.2.fill" : "speaker.slash"
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                          accessibilityDescription: "StereoPair")
        // Carry a title too: an image-only button whose symbol fails to load is
        // zero-width, and the item is invisible rather than merely ugly.
        statusItem.button?.title = "L·R"
        statusItem.button?.imagePosition = .imageLeading
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPeers()
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        refresh()
    }

    @objc private func quit() {
        sender?.terminate()
        receiver?.terminate()
        NSApp.terminate(nil)
    }
}

func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let menu = MainActor.assumeIsolated { Menu() }
    _ = menu
    app.run()
    exit(0)
}
