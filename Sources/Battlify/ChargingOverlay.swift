import Foundation
import Combine
import AppKit
import SwiftUI
import BattlifyKit

/// Shows the full-screen dot-matrix charging animation when the charger is plugged in,
/// then dismisses it after a few seconds (or on click / Esc).
@MainActor
final class ChargingOverlay: ObservableObject {
    private weak var settings: AppSettings?
    private weak var battery: BatteryStore?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var lastPlugged: Bool?

    private var window: NSWindow?
    private var keyMonitor: Any?
    private var dismissWork: DispatchWorkItem?
    private let showFor: TimeInterval = 4.5

    func startIfNeeded(settings: AppSettings, battery: BatteryStore) {
        guard !started else { return }
        started = true
        self.settings = settings
        self.battery = battery
        lastPlugged = battery.snapshot.isPluggedIn   // baseline; launching-while-plugged won't fire
        battery.objectWillChange
            .sink { [weak self] in Task { @MainActor in self?.checkPlugEdge() } }
            .store(in: &cancellables)
    }

    private func checkPlugEdge() {
        guard let battery, let settings else { return }
        let plugged = battery.snapshot.isPluggedIn
        defer { lastPlugged = plugged }
        guard settings.chargingAnimationEnabled, lastPlugged == false, plugged else { return }
        show(percentage: battery.snapshot.percentage)
    }

    /// Present the animation full-screen (also used by the Settings "Preview" button).
    func show(percentage: Int) {
        dismiss()
        // NSScreen.main is nil for an agent app with no key window; fall back.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear                 // transparent: screen stays visible
        w.ignoresMouseEvents = true                // non-blocking overlay on top of everything
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.hasShadow = false

        let host = NSHostingView(rootView: ChargingAnimationView(percentage: percentage))
        host.layer?.backgroundColor = .clear
        w.contentView = host
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showFor, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel(); dismissWork = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.6; w.animator().alphaValue = 0 },
                                             completionHandler: { w.orderOut(nil) })
    }
}
