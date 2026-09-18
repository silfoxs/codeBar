import AppKit
import SwiftUI

@main
struct AIUsageBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = UsageModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.notice("application launched")
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .noImage
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        let controller = NSHostingController(rootView: UsagePopoverView(model: model, openSettings: openSettings))
        controller.sizingOptions = []
        popover.contentViewController = controller
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentSize = NSSize(width: PopoverLayout.width, height: PopoverLayout.height)
        model.onChange = { [weak self] in self?.updateStatusItem() }
        model.onRefreshIntervalChange = { [weak self] in self?.scheduleRefreshTimer() }
        updateStatusItem()
        model.refresh()
        scheduleRefreshTimer()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            // Activating an accessory app can restore its last key window.
            // Settings belongs only to the explicit settings button.
            settingsWindow?.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            installClickMonitors()
            model.refreshIfNeeded()
        }
    }

    func applicationDidResignActive(_ notification: Notification) { popover?.performClose(nil) }

    private func installClickMonitors() {
        removeClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
            } else if event.window !== self.popover.contentViewController?.view.window,
                      event.window !== self.statusItem.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) { removeClickMonitors() }
    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        removeClickMonitors()
    }

    private func updateStatusItem() {
        let remaining = model.primaryUsage?.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        statusItem.button?.image = nil
        statusItem.button?.title = remaining
        statusItem.button?.setAccessibilityLabel(model.text("剩余用量：", "Remaining usage: ") + remaining)
        statusItem.button?.toolTip = model.text("剩余用量：", "Remaining usage: ") + remaining
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Double(model.refreshInterval.rawValue), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func openSettings() {
        AppLog.ui.debug("opening settings")
        popover.performClose(nil)
        if settingsWindow == nil {
            let view = SettingsView(model: model)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = model.text("设置", "Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 430))
            window.center()
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.title = model.text("设置", "Settings")
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
