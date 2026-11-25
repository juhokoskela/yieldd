import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CompanionModel {
    private(set) var snapshot: AgentControlSnapshot?
    private(set) var error: String?
    private(set) var rejectedChange: String?
    private(set) var changing = false
    private(set) var checking = true
    private var revision = 0
    private var refreshing = false
    private let request: @Sendable (String) throws -> AgentControlSnapshot

    init(request: @escaping @Sendable (String) throws -> AgentControlSnapshot = {
        try requestAgentControl($0, timeout: 3)
    }) {
        self.request = request
    }

    @discardableResult
    func update(_ command: String = "status") async -> String? {
        let refresh = command == "status"
        guard !changing, !refresh || !refreshing else { return nil }
        if refresh { refreshing = true } else { changing = true }
        revision += 1
        let current = revision
        defer { if refresh { refreshing = false } else { changing = false } }
        do {
            let value: AgentControlSnapshot = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [request] in
                    continuation.resume(with: Result { try request(command) })
                }
            }
            guard current == revision else { return nil }
            if !refresh { rejectedChange = nil }
            error = rejectedChange
            snapshot = value
        } catch {
            guard current == revision else { return nil }
            if refresh { snapshot = nil }
            let message = describeError(error)
            if !refresh, case AgentControlError.rejected = error { rejectedChange = message }
            self.error = message
            checking = false
            return message
        }
        checking = false
        return nil
    }

    func dismissRejection() {
        if error == rejectedChange { error = nil }
        rejectedChange = nil
    }

    var runningCount: Int { snapshot?.workers.count(where: { $0.phase == .running }) ?? 0 }

    var idleRefreshInterval: Duration {
        guard let snapshot else { return .seconds(60) }
        return snapshot.activeAssignments > 0 ? .seconds(5) : .seconds(30)
    }

    var admission: String {
        guard let snapshot else { return checking ? "Checking agent…" : "Agent unavailable" }
        if snapshot.pausedByBattery == true { return "New jobs paused on battery" }
        if snapshot.paused { return "New jobs paused" }
        switch snapshot.phase {
        case .ready: return "Accepting new jobs"
        case .starting: return "Agent starting"
        case .recovering: return "Recovering runners"
        case .stopping: return "Agent stopping"
        }
    }
}

@MainActor
func runCompanion() {
    let app = NSApplication.shared
    let delegate = CompanionDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

@MainActor
final class CompanionDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model: CompanionModel
    private var item: NSStatusItem?
    private var settings: NSWindowController?
    private var logWindow: NSWindowController?
    private var polling: Task<Void, Never>?
    private weak var openMenu: NSMenu?

    init(model: CompanionModel = CompanionModel()) { self.model = model }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        item = statusItem
        updateIcon()

        let main = NSMenu()
        let application = NSMenu()
        application.addItem(command("Settings…", #selector(showSettings), key: ","))
        application.addItem(.separator())
        application.addItem(command("Quit yieldd", #selector(quit), key: "q"))
        main.addItem(withTitle: "yieldd", action: nil, keyEquivalent: "").submenu = application
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.mainMenu = main
        polling = Task {
            while !Task.isCancelled {
                await refreshPresentation()
                let visible = openMenu != nil || settings?.window?.isVisible == true
                let delay = visible ? .seconds(5) : model.idleRefreshInterval
                do { try await Task.sleep(for: delay, tolerance: .seconds(1)) } catch { return }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { polling?.cancel() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    private func updateIcon() {
        guard let button = item?.button else { return }
        let workers = model.snapshot?.workers ?? []
        let running = model.runningCount
        let issue = workers.contains { $0.connection == .retrying || $0.connection == .failed }
        let symbol: String
        if issue || (model.snapshot == nil && !model.checking) { symbol = "exclamationmark.triangle" }
        else if model.snapshot?.paused == true { symbol = "pause.circle" }
        else if running > 0 { symbol = "play.circle.fill" }
        else { symbol = "square.stack.3d.up" }
        let description = ["yieldd", model.admission, running > 0 ? "\(running) running" : nil, issue ? "Connection issue" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        guard button.toolTip != description else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    private func command(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        Task { await refreshPresentation() }
    }

    func menuDidClose(_ menu: NSMenu) { openMenu = nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let running = model.runningCount
        let title = running == 0 ? model.admission : "\(model.admission) · \(running) running"
        let summary = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.sizeToFit()
        let inset: CGFloat = 14
        let header = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + inset * 2, height: label.frame.height + 10))
        label.setFrameOrigin(NSPoint(x: inset, y: 5))
        header.addSubview(label)
        summary.view = header
        menu.addItem(summary)
        if let snapshot = model.snapshot {
            for worker in snapshot.workers {
                let several = snapshot.workers.contains { $0.id != worker.id && $0.platform == worker.platform }
                let title = worker.platform == .macOS ? "macOS" : "Linux"
                let phase = worker.phase.menuDescription
                let row = NSMenuItem(title: several ? "\(title) · Slot \(worker.slot + 1)" : title, action: nil, keyEquivalent: "")
                let connection: String? = switch worker.connection {
                case .connecting: snapshot.paused && worker.phase == .idle ? nil : "Connecting"
                case .retrying: "Reconnecting"
                case .failed: "Connection failed"
                case .connected: nil
                }
                let showPhase = worker.phase != .idle || connection == nil
                let activity = [showPhase ? phase : nil, worker.repository, connection].compactMap { $0 }
                let activityText = activity.joined(separator: " · ")
                row.subtitle = activityText
                row.setAccessibilityLabel([row.title, row.subtitle].compactMap { $0 }.joined(separator: ", "))
                let details = NSMenu()
                details.autoenablesItems = false
                let contact = worker.lastContactAt.map { "Last contact " + $0.formatted(.relative(presentation: .named)) }
                for line in [worker.runner, contact].compactMap({ $0 }) {
                    let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    info.isEnabled = false
                    details.addItem(info)
                }
                if !details.items.isEmpty { details.addItem(.separator()) }
                let copy = command("Copy Runner Details", #selector(copyText(_:)))
                copy.representedObject = [worker.id, activityText, worker.runner, contact].compactMap { $0 }.joined(separator: "\n")
                details.addItem(copy)
                row.submenu = details
                menu.addItem(row)
            }
            let manual = snapshot.manuallyPaused ?? snapshot.paused
            menu.addItem(.separator())
            let title = manual ? (snapshot.pausedByBattery == true ? "Clear Manual Pause" : "Resume New Jobs") : "Pause New Jobs"
            let toggle = command(title, manual ? #selector(resumeJobs) : #selector(pauseJobs))
            if snapshot.pausedByBattery == true && !manual {
                toggle.subtitle = "Stay paused when power is connected"
            }
            toggle.isEnabled = !model.changing
            menu.addItem(toggle)
            if snapshot.pausedByBattery == true && !manual {
                let allow = command("Allow New Jobs on Battery", #selector(allowOnBattery))
                allow.subtitle = "Turns off the battery pause setting"
                allow.isEnabled = !model.changing
                menu.addItem(allow)
            }
        } else if !model.checking {
            menu.addItem(command("Check Again", #selector(refresh)))
        }
        menu.addItem(.separator())
        if let error = model.snapshot?.lastError {
            let copy = command("Copy Last Agent Error", #selector(copyText(_:)))
            let preview = error.message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            copy.subtitle = preview.count > 64 ? String(preview.prefix(63)) + "…" : preview
            copy.toolTip = error.message
            copy.representedObject = error.message
            menu.addItem(copy)
        }
        menu.addItem(command("Show Agent Log", #selector(showAgentLog)))
        menu.addItem(.separator())
        menu.addItem(command("Settings…", #selector(showSettings), key: ","))
        menu.addItem(command("Quit yieldd", #selector(quit), key: "q"))
    }

    @discardableResult
    private func refreshPresentation(_ command: String = "status") async -> String? {
        let previous = model.snapshot
        let admission = model.admission
        let error = await model.update(command)
        updateIcon()
        if let menu = openMenu {
            let current = model.snapshot
            if admission != model.admission || previous?.workers != current?.workers ||
                previous?.manuallyPaused != current?.manuallyPaused || previous?.lastError != current?.lastError {
                menuNeedsUpdate(menu)
            }
        }
        return error
    }

    private func send(_ command: String) {
        Task {
            let failure = await refreshPresentation(command)
            if failure != nil { presentSettings() }
        }
    }
    @objc private func refresh() { send("status") }
    @objc private func pauseJobs() { send("pause") }
    @objc private func resumeJobs() { send("resume") }
    @objc private func allowOnBattery() { send("allow-on-battery") }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func copyText(_ item: NSMenuItem) {
        guard let details = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }
    @objc private func showAgentLog() {
        if logWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: CompanionLog()))
            window.delegate = self
            window.title = "yieldd Agent Log"
            window.setContentSize(NSSize(width: 700, height: 360))
            window.isReleasedWhenClosed = false
            window.center()
            logWindow = NSWindowController(window: window)
        }
        NSApp.activate()
        logWindow?.showWindow(nil)
        logWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === logWindow?.window { logWindow = nil }
        if window === settings?.window { settings = nil }
    }

    @objc func showSettings() {
        Task { await refreshPresentation() }
        presentSettings()
    }

    private func presentSettings() {
        if settings == nil {
            let controller = NSHostingController(rootView: CompanionSettings(model: model) { [weak self] enabled in
                self?.send(enabled ? "pause-on-battery" : "allow-on-battery")
            })
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.delegate = self
            window.title = "yieldd Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settings = NSWindowController(window: window)
        }
        NSApp.activate()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
}

extension AgentWorkerPhase {
    var menuDescription: String {
        switch self {
        case .idle: "Idle"
        case .waitingForMemory: "Waiting for memory"
        case .provisioning: "Preparing runner"
        case .waitingForJob: "Waiting for job"
        case .running: "Running job"
        case .cleaningUp: "Cleaning up"
        case .recovering: "Recovering"
        }
    }
}
