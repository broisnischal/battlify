cask "battpie" do
  version "0.1.0"
  # Replace with: shasum -a 256 dist/BattPie-<version>.zip
  sha256 "REPLACE_WITH_SHA256_OF_ZIP"

  # Point at your GitHub release artifact produced by scripts/package-app.sh.
  url "https://github.com/OWNER/battpie/releases/download/v#{version}/BattPie-#{version}.zip"
  name "BattPie"
  desc "Menu bar battery saver and charge limiter for Apple Silicon Macs"
  homepage "https://github.com/OWNER/battpie"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "BattPie.app"

  caveats <<~EOS
    Charge limiting, Low Power Mode toggling, and history-while-logged-out need a
    small root helper (a LaunchDaemon).

    After first launch, open the BattPie menu-bar item and click
    "Install Helper…" — you'll be asked for your password once.

    The helper re-enables charging automatically if it ever stops, so your Mac is
    never left unable to charge.
  EOS

  uninstall quit:   "com.battpie.app",
            script: {
              executable: "#{appdir}/BattPie.app/Contents/Resources/uninstall-helper.sh",
              sudo:       true,
            }

  zap trash: [
    "~/Library/Application Support/BattPie",
    "~/Library/Preferences/com.battpie.app.plist",
    "/Library/Application Support/BattPie",
    "/Library/LaunchDaemons/com.battpie.helper.plist",
    "/usr/local/bin/battpie-helper",
  ]
end
