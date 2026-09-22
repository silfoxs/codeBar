import AppKit
import SwiftUI

@main
struct CodeBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = UsageModel()
    let updateManager = UpdateManager()
    private var statusItem: NSStatusItem!
    private var usagePanel: UsagePanel?
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

        let controller = NSHostingController(rootView: UsagePopoverView(model: model, openSettings: openSettings))
        controller.sizingOptions = []
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        let panel = UsagePanel(contentRect: NSRect(origin: .zero,
                                                    size: NSSize(width: PopoverLayout.width, height: PopoverLayout.height)),
                               contentViewController: controller)
        panel.delegate = self
        usagePanel = panel
        model.onChange = { [weak self] in self?.updateStatusItem() }
        model.onRefreshIntervalChange = { [weak self] in self?.scheduleRefreshTimer() }
        updateStatusItem()
        model.refresh()
        scheduleRefreshTimer()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if usagePanel?.isVisible == true { closeUsagePanel() }
        else {
            // Activating an accessory app can restore its last key window.
            // Settings belongs only to the explicit settings button.
            settingsWindow?.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            showUsagePanel(relativeTo: button)
            installClickMonitors()
            model.refreshIfNeeded()
        }
    }

    func applicationDidResignActive(_ notification: Notification) { closeUsagePanel() }

    private func installClickMonitors() {
        removeClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeUsagePanel()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.usagePanel?.isVisible == true else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closeUsagePanel(); return nil }
            } else if event.window !== self.usagePanel,
                      event.window !== self.statusItem.button?.window {
                self.closeUsagePanel()
            }
            return event
        }
    }

    private func closeUsagePanel() {
        removeClickMonitors()
        if usagePanel?.isVisible == true { usagePanel?.orderOut(nil) }
        model.hoveredBlockID = nil
    }

    private func removeClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

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
        closeUsagePanel()
        if settingsWindow == nil {
            let view = SettingsView(model: model, updateManager: updateManager)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = model.text("设置", "Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 620))
            window.center()
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.title = model.text("设置", "Settings")
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showUsagePanel(relativeTo button: NSStatusBarButton) {
        guard let panel = usagePanel,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = NSSize(width: PopoverLayout.width, height: PopoverLayout.height)
        let visible = screen.visibleFrame
        let x = min(max(buttonRect.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let below = buttonRect.minY - size.height - 8
        let y = max(visible.minY + 8, min(below, visible.maxY - size.height - 8))
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

private final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, contentViewController: NSViewController) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.transient, .moveToActiveSpace]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
    }
}
