import Foundation
import Combine
import AppKit
import BattlifyKit

/// Drives in-app update checks against a public JSON feed. Checks on launch and
/// once a day, plus on demand. Surfaces an available update for the menu to show.
@MainActor
final class UpdaterManager: ObservableObject {
    @Published private(set) var available: AppUpdate?
    @Published private(set) var checking = false
    @Published private(set) var lastResult: String?

    /// Public update feed. Host this JSON anywhere reachable without auth
    /// (GitHub Pages, a public releases repo, your storefront/CDN).
    let feedURL = URL(string: "https://raw.githubusercontent.com/broisnischal/battlify-releases/main/appcast.json")!

    let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

    private var timer: Timer?

    init() {
        check(userInitiated: false)
        // Re-check once a day.
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(userInitiated: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        let feed = feedURL
        let current = currentVersion
        Task.detached {
            var found: AppUpdate?
            var message: String?
            do {
                found = try await UpdateChecker.check(feedURL: feed, currentVersion: current)
                message = found == nil ? "You're up to date (v\(current))." : nil
            } catch {
                message = "Couldn't check for updates."
            }
            let result = found
            let msg = message
            await MainActor.run {
                self.available = result
                self.lastResult = msg
                self.checking = false
                if userInitiated, result == nil {
                    self.showInfoAlert(msg ?? "You're up to date.")
                }
            }
        }
    }

    /// Open the DMG download (browser/Finder handles it; user drags to Applications).
    func downloadAvailable() {
        guard let u = available?.url else { return }
        NSWorkspace.shared.open(u)
    }

    private func showInfoAlert(_ text: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Battlify"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
