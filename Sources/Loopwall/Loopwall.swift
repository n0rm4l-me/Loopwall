import AppKit
import AVFoundation
import IOKit.ps
import ServiceManagement

private let kLastVideoURLKey = "lastVideoURL"
private let kPauseWhenHiddenKey = "pauseWhenHidden"
private let kPauseOnBatteryKey = "pauseOnBattery"
private let kPauseWhenOverheatingKey = "pauseWhenOverheating"

/// Energy-saver settings default to ON. `object(forKey:)` returns nil when the
/// key was never written, so treat nil as the enabled default.
private func energySaverEnabled(_ key: String) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? true
}

struct ScreenPlayer {
    let player: AVPlayer
    let window: NSWindow
    let loopToken: Any
}

@MainActor
final class LoopwallApp: NSObject, NSApplicationDelegate {
    var screenPlayers: [ScreenPlayer] = []
    var statusItem: NSStatusItem?

    /// Set while the user has explicitly paused via the menu; separate from the
    /// automatic energy-saver pause so the two can't clobber each other.
    var userPaused = false
    /// Registered IOKit power-source run-loop source, torn down on demand.
    var powerSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        start(pickNew: false)

        // Rebuild windows when monitors are connected, disconnected, or rearranged
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        setupEnergyMonitoring()
    }

    @objc func screensChanged() {
        // Reuse the current video; no picker
        guard !screenPlayers.isEmpty else { return }
        start(pickNew: false)
    }

    // MARK: - Energy saver

    func setupEnergyMonitoring() {
        // Desktop visibility. Our windows sit at desktop level, so they never
        // report `.visible` via occlusionState — instead we poll CGWindowList
        // (see isDesktopHidden) whenever the front app or Space changes.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(energyConditionChanged),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(energyConditionChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Thermal pressure
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyConditionChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        // Power source (AC vs battery). IOKit posts to a run-loop source.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let app = Unmanaged<LoopwallApp>.fromOpaque(context).takeUnretainedValue()
            // Notification arrives on the main run loop; hop onto the main actor.
            Task { @MainActor in app.energyConditionChanged() }
        }, context)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    @objc func energyConditionChanged() {
        evaluatePlayback()
    }

    /// True when any enabled energy-saver condition says playback should pause.
    var shouldPauseForEnergy: Bool {
        if energySaverEnabled(kPauseWhenHiddenKey), isDesktopHidden { return true }
        if energySaverEnabled(kPauseOnBatteryKey), isOnBattery { return true }
        if energySaverEnabled(kPauseWhenOverheatingKey), isOverheating { return true }
        return false
    }

    /// True when every wallpaper screen is fully covered by a normal-level
    /// window from another app (fullscreen app, maximized window, …). Because
    /// one shared player drives all screens, we only pause when the desktop is
    /// hidden on ALL of them — if any screen still shows the wallpaper, keep
    /// playing. Uses CGWindowList because desktop-level windows never report
    /// `.visible` through occlusionState.
    var isDesktopHidden: Bool {
        guard !screenPlayers.isEmpty else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        // Height of the display anchored at (0,0) — flips AppKit's bottom-left
        // origin to CGWindowList's top-left origin.
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?
            .frame.height ?? NSScreen.main?.frame.height ?? 0

        for sp in screenPlayers {
            let f = sp.window.frame
            let screenCG = CGRect(
                x: f.origin.x,
                y: primaryHeight - f.origin.y - f.height,
                width: f.width,
                height: f.height
            )
            var covered = false
            for w in info {
                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                      let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
                if bounds.insetBy(dx: -2, dy: -2).contains(screenCG) { covered = true; break }
            }
            if !covered { return false }  // this screen still shows the wallpaper
        }
        return true  // every screen is covered
    }

    var isOnBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)
                .takeUnretainedValue() as? [String: Any],
                let state = desc[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    var isOverheating: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// Single source of truth for play/pause. Never recreates windows.
    func evaluatePlayback() {
        guard let player = screenPlayers.first?.player else { return }
        let shouldPlay = !userPaused && !shouldPauseForEnergy
        if shouldPlay {
            if player.timeControlStatus == .paused { player.play() }
        } else {
            if player.timeControlStatus != .paused { player.pause() }
        }
        updateMenuState()
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

        // Energy Saver submenu
        let energyItem = NSMenuItem(title: "Energy Saver", action: nil, keyEquivalent: "")
        let energyMenu = NSMenu()
        let hiddenItem = NSMenuItem(title: "Pause When Desktop Is Hidden", action: #selector(togglePauseWhenHidden), keyEquivalent: "")
        hiddenItem.tag = 10
        energyMenu.addItem(hiddenItem)
        let batteryItem = NSMenuItem(title: "Pause on Battery Power", action: #selector(togglePauseOnBattery), keyEquivalent: "")
        batteryItem.tag = 11
        energyMenu.addItem(batteryItem)
        let heatItem = NSMenuItem(title: "Pause When Overheating", action: #selector(togglePauseWhenOverheating), keyEquivalent: "")
        heatItem.tag = 12
        energyMenu.addItem(heatItem)
        energyItem.submenu = energyMenu
        menu.addItem(energyItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    func updateMenuState() {
        guard let menu = statusItem?.menu else { return }
        if let muteItem = menu.item(withTag: 1) {
            let isMuted = screenPlayers.first?.player.isMuted ?? true
            muteItem.state = isMuted ? .on : .off
        }
        if let launchItem = menu.item(withTag: 2) {
            launchItem.state = launchAtLoginEnabled ? .on : .off
        }
        if let energySubmenu = menu.items.first(where: { $0.title == "Energy Saver" })?.submenu {
            energySubmenu.item(withTag: 10)?.state = energySaverEnabled(kPauseWhenHiddenKey) ? .on : .off
            energySubmenu.item(withTag: 11)?.state = energySaverEnabled(kPauseOnBatteryKey) ? .on : .off
            energySubmenu.item(withTag: 12)?.state = energySaverEnabled(kPauseWhenOverheatingKey) ? .on : .off
        }
    }

    // MARK: - Playback

    func start(pickNew: Bool) {
        guard let videoURL = resolveVideoURL(pickNew: pickNew) else {
            if screenPlayers.isEmpty { NSApp.terminate(nil) }
            return
        }

        // Save for next launch
        UserDefaults.standard.set(videoURL.path, forKey: kLastVideoURLKey)

        // Tear down previous players
        stopAll()

        // One shared decoder, one layer per screen
        let player = AVPlayer(url: videoURL)
        player.actionAtItemEnd = .none
        player.isMuted = true

        let token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        for screen in NSScreen.screens {
            let window = makeDesktopWindow(for: screen)
            let layer = AVPlayerLayer(player: player)
            layer.frame = CGRect(origin: .zero, size: screen.frame.size)
            layer.videoGravity = .resizeAspectFill

            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.addSublayer(layer)
            window.contentView = view

            window.orderFrontRegardless()
            screenPlayers.append(ScreenPlayer(player: player, window: window, loopToken: token))
        }

        // Respect energy-saver state instead of unconditionally playing
        evaluatePlayback()
    }

    func stopAll() {
        // One token shared across all layers for the same player — remove once
        if let token = screenPlayers.first?.loopToken {
            NotificationCenter.default.removeObserver(token)
        }
        for sp in screenPlayers {
            sp.player.pause()
            sp.window.orderOut(nil)
        }
        screenPlayers.removeAll()
    }

    func makeDesktopWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.setFrameOrigin(screen.frame.origin)
        return window
    }

    // MARK: - Menu actions

    @objc func changeVideo() {
        start(pickNew: true)
    }

    @objc func toggleMute() {
        let newMuted = !(screenPlayers.first?.player.isMuted ?? true)
        screenPlayers.first?.player.isMuted = newMuted
        updateMenuState()
    }

    @objc func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchAtLoginEnabled)
        updateMenuState()
    }

    @objc func togglePauseWhenHidden() {
        UserDefaults.standard.set(!energySaverEnabled(kPauseWhenHiddenKey), forKey: kPauseWhenHiddenKey)
        evaluatePlayback()
    }

    @objc func togglePauseOnBattery() {
        UserDefaults.standard.set(!energySaverEnabled(kPauseOnBatteryKey), forKey: kPauseOnBatteryKey)
        evaluatePlayback()
    }

    @objc func togglePauseWhenOverheating() {
        UserDefaults.standard.set(!energySaverEnabled(kPauseWhenOverheatingKey), forKey: kPauseWhenOverheatingKey)
        evaluatePlayback()
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
        let url = URL(fileURLWithPath: args[1])
        if FileManager.default.fileExists(atPath: url.path) { return url }
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
    if #available(macOS 14, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = LoopwallApp()
app.delegate = delegate
app.run()
