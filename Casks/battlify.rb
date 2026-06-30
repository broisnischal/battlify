cask "battlify" do
  version "0.1.0"
  # Replace with: shasum -a 256 dist/Battlify-<version>.zip
  sha256 "REPLACE_WITH_SHA256_OF_ZIP"

  # Point at your GitHub release artifact produced by scripts/package-app.sh.
  url "https://github.com/OWNER/battlify/releases/download/v#{version}/Battlify-#{version}.zip"
  name "Battlify"
  desc "Menu bar battery saver and charge limiter for Apple Silicon Macs"
  homepage "https://github.com/OWNER/battlify"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Battlify.app"

  caveats <<~EOS
    Charge limiting, Low Power Mode toggling, and history-while-logged-out need a
    small root helper (a LaunchDaemon).

    After first launch, open the Battlify menu-bar item and click
    "Install Helper…" — you'll be asked for your password once.

    The helper re-enables charging automatically if it ever stops, so your Mac is
    never left unable to charge.
  EOS

  uninstall quit:   "com.battlify.app",
            script: {
              executable: "#{appdir}/Battlify.app/Contents/Resources/uninstall-helper.sh",
              sudo:       true,
            }

  zap trash: [
    "~/Library/Application Support/Battlify",
    "~/Library/Preferences/com.battlify.app.plist",
    "/Library/Application Support/Battlify",
    "/Library/LaunchDaemons/com.battlify.helper.plist",
    "/usr/local/bin/battlify-helper",
  ]
end
