import AppKit
import SwiftUI
import Sub2APIStatusCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = MonitorViewModel()
    private let menuBarStatusView = MenuBarStatusView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.addSubview(menuBarStatusView)
            button.image = nil
            button.title = ""
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 520, height: 680)
        popover.delegate = self
        applyAppearance(model.config.appearance)
        popover.contentViewController = NSHostingController(
            rootView: MonitorPanel(model: model)
            .environment(\.appLanguage, model.config.language)
            .appAppearance(model.config.appearance)
            .tint(ClaudeTheme.accent)
        )

        model.onSnapshotChange = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
        }
        model.onAppearanceChange = { [weak self] appearance in
            self?.applyAppearance(appearance)
        }
        model.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                self?.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func updateStatusItem(_ snapshot: MonitorSnapshot) {
        guard let button = statusItem?.button else {
            return
        }

        let strings = AppStrings(model.config.language)
        let localizedStatus = strings.statusLabel(for: snapshot)
        let presentation = snapshot.menuBarStatusPresentation(config: model.config)
        button.image = nil
        button.title = ""
        menuBarStatusView.update(presentation: presentation, fallbackTitle: localizedStatus)
        let targetLength = menuBarStatusView.fittingSize.width
        if let statusItem, abs(statusItem.length - targetLength) > 0.5 {
            statusItem.length = targetLength
        }
        button.toolTip = snapshot.menuBarTooltip(statusText: localizedStatus, config: model.config)
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        let nsAppearance = appearance.nsAppearance
        NSApp.appearance = nsAppearance
        popover.appearance = nsAppearance
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopAllCodexTunnels()
    }
}
