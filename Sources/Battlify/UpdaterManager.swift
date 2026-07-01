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
    @Published private(set) var installing = false
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
        t.tolerance = 3600   // daily check; an hour of slack lets the OS batch it
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

    /// Open the DMG download in the browser (manual fallback: user drags to
    /// Applications). Used when the in-place installer can't run.
    func downloadAvailable() {
        guard let u = available?.url else { return }
        NSWorkspace.shared.open(u)
    }

    /// Download the update DMG and install it *in place* over the running app,
    /// then relaunch — no manual drag/replace. If anything blocks the automatic
    /// path (e.g. the app lives somewhere unwritable), falls back to opening the
    /// DMG so the user can install it by hand.
    func installUpdate() {
        guard !installing, let url = available?.url else { return }
        let bundlePath = Bundle.main.bundlePath
        let parent = (bundlePath as NSString).deletingLastPathComponent

        // Fail fast (before we download or quit) if we can't replace the bundle.
        guard FileManager.default.isWritableFile(atPath: parent) else {
            showInfoAlert("Battlify can't update itself here because \(parent) isn't writable. Opening the download so you can install it manually.")
            downloadAvailable()
            return
        }

        installing = true
        lastResult = nil
        let pid = ProcessInfo.processInfo.processIdentifier
        Task.detached {
            do {
                try await Self.performInstall(from: url, bundlePath: bundlePath, pid: pid)
                // The swap script now waits for us to quit, then relaunches.
                await MainActor.run { NSApplication.shared.terminate(nil) }
            } catch {
                await MainActor.run {
                    self.installing = false
                    self.showInfoAlert("Couldn't install the update automatically (\(error.localizedDescription)). Opening the download so you can install it manually.")
                    self.downloadAvailable()
                }
            }
        }
    }

    // MARK: - In-place install (Sparkle-lite)

    private enum UpdaterError: LocalizedError {
        case appNotFoundInDMG
        case tool(String, String)

        var errorDescription: String? {
            switch self {
            case .appNotFoundInDMG: return "the update disk image didn't contain Battlify.app"
            case .tool(let name, let msg):
                let detail = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(name) failed" + (detail.isEmpty ? "" : ": \(detail)")
            }
        }
    }

    /// Downloads the DMG, mounts it, and hands off to a detached shell script that
    /// waits for this process to exit, swaps the bundle, and relaunches. Runs off
    /// the main actor — it only touches local files, not published state.
    nonisolated private static func performInstall(from url: URL, bundlePath: String, pid: Int32) async throws {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory()
        let stamp = UUID().uuidString

        // 1. Download the DMG to a stable temp path.
        let (downloaded, _) = try await URLSession.shared.download(from: url)
        let dmgPath = tmp + "battlify-update-\(stamp).dmg"
        try? fm.removeItem(atPath: dmgPath)
        try fm.moveItem(atPath: downloaded.path, toPath: dmgPath)

        // 2. Mount it on a private, non-browsable mount point.
        let mountPoint = tmp + "battlify-mnt-\(stamp)"
        try fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        try runTool("/usr/bin/hdiutil",
                    ["attach", dmgPath, "-nobrowse", "-noverify", "-mountpoint", mountPoint])

        // 3. Locate the .app inside the image.
        let appName = (bundlePath as NSString).lastPathComponent   // e.g. "Battlify.app"
        let srcApp = mountPoint + "/" + appName
        guard fm.fileExists(atPath: srcApp) else {
            try? runTool("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
            throw UpdaterError.appNotFoundInDMG
        }

        // 4. Swap-and-relaunch script. It waits for THIS pid to exit so it never
        //    overwrites a running bundle, keeps a .bak to roll back on failure,
        //    clears quarantine, refreshes Launch Services (so the new bundle isn't
        //    shadowed by a stale registration), then relaunches. All output goes to
        //    a log file so the parent's closing pipes can't SIGPIPE it mid-run.
        let logPath = tmp + "battlify-update.log"
        let script = """
        #!/bin/bash
        exec >>"\(logPath)" 2>&1
        echo "=== $(date) Battlify updater (pid \(pid)) ==="
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        echo "app exited; installing update"
        if /usr/bin/ditto "\(srcApp)" "\(bundlePath).new"; then
          /usr/bin/xattr -dr com.apple.quarantine "\(bundlePath).new" 2>/dev/null || true
          /bin/rm -rf "\(bundlePath).bak"
          /bin/mv "\(bundlePath)" "\(bundlePath).bak" 2>/dev/null || true
          if /bin/mv "\(bundlePath).new" "\(bundlePath)"; then
            echo "swap ok"
            /bin/rm -rf "\(bundlePath).bak"
          else
            echo "swap failed; restoring backup"
            /bin/mv "\(bundlePath).bak" "\(bundlePath)" 2>/dev/null || true
          fi
        else
          echo "ditto failed"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "\(bundlePath)" 2>/dev/null || true
        /usr/bin/hdiutil detach "\(mountPoint)" -quiet 2>/dev/null || /usr/bin/hdiutil detach "\(mountPoint)" -force 2>/dev/null || true
        /bin/rm -f "\(dmgPath)"
        /bin/rmdir "\(mountPoint)" 2>/dev/null || true
        LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        "$LSREG" -f "\(bundlePath)" 2>/dev/null || true
        echo "launching \(bundlePath)"
        /usr/bin/open "\(bundlePath)" || /usr/bin/open -a "\(bundlePath)"
        echo "done"
        /bin/rm -f "$0"
        """
        let scriptPath = tmp + "battlify-update-\(stamp).sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // 5. Launch it fully detached (nohup + background in a throwaway shell) so it
        //    survives this app terminating — a direct child can be torn down with the
        //    parent and never finish the swap/relaunch. Then the caller quits the app.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "/usr/bin/nohup /bin/bash \"\(scriptPath)\" >/dev/null 2>&1 &"]
        try p.run()
    }

    nonisolated private static func runTool(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdaterError.tool((path as NSString).lastPathComponent, msg)
        }
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
