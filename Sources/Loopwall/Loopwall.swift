import AppKit
import AVFoundation
import ServiceManagement

private let kLastVideoURLKey = "lastVideoURL"

@MainActor
final class LoopwallApp: NSObject, NSApplicationDelegate {
    var players: [(AVPlayer, NSWindow)] = []
    var loopObservers: [Any] = []
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        start(pickNew: false)
    }

    // MARK: - Status bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Loopwall")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Change Video…", action: #selector(changeVideo), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())

        let muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        muteItem.tag = 1
        menu.addItem(muteItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.tag = 2
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    func updateMenuState() {
        guard let menu = statusItem?.menu else { return }
        if let muteItem = menu.item(withTag: 1) {
            let isMuted = players.first?.0.isMuted ?? true
            muteItem.state = isMuted ? .on : .off
        }
        if let launchItem = menu.item(withTag: 2) {
            launchItem.state = launchAtLoginEnabled ? .on : .off
        }
    }

    // MARK: - Playback

    func start(pickNew: Bool) {
        guard let videoURL = resolveVideoURL(pickNew: pickNew) else {
            if players.isEmpty { NSApp.terminate(nil) }
            return
        }

        // Save for next launch
        UserDefaults.standard.set(videoURL.path, forKey: kLastVideoURLKey)

        // Tear down previous players
        stopAll()

        // Create one player per screen
        for screen in NSScreen.screens {
            let window = makeDesktopWindow(for: screen)
            let player = AVPlayer(url: videoURL)
            let layer = AVPlayerLayer(player: player)
            layer.frame = screen.frame
            layer.videoGravity = .resizeAspectFill

            let view = NSView(frame: screen.frame)
            view.wantsLayer = true
            view.layer?.addSublayer(layer)
            window.contentView = view

            let token = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
            loopObservers.append(token)

            player.isMuted = true
            player.play()
            window.makeKeyAndOrderFront(nil)
            players.append((player, window))
        }

        updateMenuState()
    }

    func stopAll() {
        for (player, window) in players {
            player.pause()
            window.orderOut(nil)
        }
        players.removeAll()
        loopObservers.forEach { NotificationCenter.default.removeObserver($0) }
        loopObservers.removeAll()
    }

    func makeDesktopWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        return window
    }

    // MARK: - Menu actions

    @objc func changeVideo() {
        start(pickNew: true)
    }

    @objc func toggleMute() {
        let newMuted = !(players.first?.0.isMuted ?? true)
        for (player, _) in players { player.isMuted = newMuted }
        updateMenuState()
    }

    @objc func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchAtLoginEnabled)
        updateMenuState()
    }

    // MARK: - Drag & drop onto Dock icon

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            UserDefaults.standard.set(url.path, forKey: kLastVideoURLKey)
            start(pickNew: false)
        }
    }
}

// MARK: - Launch at Login

var launchAtLoginEnabled: Bool {
    if #available(macOS 13, *) {
        return SMAppService.mainApp.status == .enabled
    }
    return false
}

func setLaunchAtLogin(_ enable: Bool) {
    if #available(macOS 13, *) {
        try? enable ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}

// MARK: - Video URL resolution

@MainActor
func resolveVideoURL(pickNew: Bool) -> URL? {
    // CLI argument takes priority
    let args = CommandLine.arguments
    if args.count > 1 {
        return URL(fileURLWithPath: args[1])
    }

    // Use remembered file unless caller wants a new one
    if !pickNew, let saved = UserDefaults.standard.string(forKey: kLastVideoURLKey) {
        let url = URL(fileURLWithPath: saved)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }

    // Auto-detect in ~/Movies
    if !pickNew {
        let moviesDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        if let file = try? FileManager.default.contentsOfDirectory(at: moviesDir, includingPropertiesForKeys: nil)
            .first(where: { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }) {
            return file
        }
    }

    // Open panel
    let panel = NSOpenPanel()
    panel.title = "Choose a video file"
    panel.message = "Select a video to use as your desktop wallpaper"
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = LoopwallApp()
app.delegate = delegate
app.run()
