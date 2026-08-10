import AppKit
import Combine
import SwiftUI
import Sub2APIStatusCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = MonitorViewModel()
    private let menuBarStatusView = MenuBarStatusView()
    private var appliedAppearance: AppAppearance?
    private var systemAppearancePollTimer: Timer?
    private var configCancellable: AnyCancellable?

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
        let appearanceViewController = NSHostingController(
            rootView: MonitorPanel(model: model)
            .environment(\.appLanguage, model.config.language)
            .tint(ClaudeTheme.accent)
        )
        popover.contentViewController = appearanceViewController
        applyAppearance(model.config.appearance)
        startSystemAppearancePolling()

        model.onSnapshotChange = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
        }
        model.onAppearanceChange = { [weak self] appearance in
            self?.applyAppearance(appearance)
        }
        configCancellable = model.$config
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.updateStatusItem(self.model.snapshot)
                }
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
                guard let self, let window = self.popover.contentViewController?.view.window else {
                    return
                }
                window.makeKey()
                if self.model.config.menuBarStatusDisplayMode == .signedOut {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    private func updateStatusItem(_ snapshot: MonitorSnapshot) {
        guard let button = statusItem?.button else {
            return
        }

        let strings = AppStrings(model.config.language)
        let localizedStatus = strings.statusLabel(for: snapshot)
        switch model.config.menuBarStatusDisplayMode {
        case .signedOut:
            updateIconStatusItem(
                button,
                systemName: "antenna.radiowaves.left.and.right",
                toolTip: strings.phrase("TokenRouter · 未登录", "TokenRouter · Signed Out")
            )
            return
        case .iconOnly:
            updateIconStatusItem(
                button,
                systemName: statusSystemImage(for: snapshot.severity),
                toolTip: snapshot.menuBarTooltip(statusText: localizedStatus, config: model.config)
            )
            return
        case .metrics:
            break
        }

        let presentation = snapshot.menuBarStatusPresentation(config: model.config)
        button.image = nil
        button.imagePosition = .noImage
        button.title = ""
        menuBarStatusView.isHidden = false
        menuBarStatusView.update(presentation: presentation, fallbackTitle: localizedStatus)
        let targetLength = menuBarStatusView.fittingSize.width
        if let statusItem, abs(statusItem.length - targetLength) > 0.5 {
            statusItem.length = targetLength
        }
        button.toolTip = snapshot.menuBarTooltip(statusText: localizedStatus, config: model.config)
        button.setAccessibilityLabel(button.toolTip)
    }

    private func updateIconStatusItem(_ button: NSStatusBarButton, systemName: String, toolTip: String) {
        menuBarStatusView.isHidden = true
        button.title = ""
        button.image = menuBarImage(systemName: systemName)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        statusItem?.length = NSStatusItem.squareLength
    }

    private func menuBarImage(systemName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let configuredImage = image?.withSymbolConfiguration(configuration) ?? image
        configuredImage?.isTemplate = true
        return configuredImage
    }

    private func statusSystemImage(for severity: MonitorSeverity) -> String {
        switch severity {
        case .healthy:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        NSApp.appearance = appearance.nsAppearance
        let resolvedAppearance = appearance == .system
            ? AppAppearance.resolved(from: NSApp.effectiveAppearance)
            : appearance
        applyResolvedAppearance(resolvedAppearance)
    }

    private func startSystemAppearancePolling() {
        systemAppearancePollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.model.config.appearance == .system else {
                    return
                }
                self.applyResolvedAppearance(AppAppearance.resolved(from: NSApp.effectiveAppearance))
            }
        }
    }

    private func applyResolvedAppearance(_ appearance: AppAppearance) {
        guard let nsAppearance = appearance.nsAppearance else {
            return
        }
        model.updateResolvedAppearance(appearance)
        guard appliedAppearance != appearance else {
            return
        }
        appliedAppearance = appearance
        popover.appearance = nsAppearance
        popover.contentViewController?.view.appearance = nsAppearance
        popover.contentViewController?.view.needsLayout = true
        popover.contentViewController?.view.needsDisplay = true
        popover.contentViewController?.view.window?.appearance = nsAppearance
        popover.contentViewController?.view.window?.contentView?.needsDisplay = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemAppearancePollTimer?.invalidate()
        model.stopHardwareMonitorBLE()
        model.stopAllCodexTunnels()
    }
}
