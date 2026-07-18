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
        w.isOpaque = true
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.hasShadow = false

        let root = ChargingAnimationView(percentage: percentage)
            .contentShape(Rectangle())
            .onTapGesture { [weak self] in self?.dismiss() }
        w.contentView = NSHostingView(rootView: root)
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return nil }   // Esc
            return event
        }

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showFor, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel(); dismissWork = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        window?.orderOut(nil)
        window = nil
    }
}
