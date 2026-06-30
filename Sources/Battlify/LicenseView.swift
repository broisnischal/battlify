import SwiftUI

struct LicenseView: View {
    @EnvironmentObject private var license: LicenseManager

    // Replace with your storefront product URL.
    private let buyURL = URL(string: "https://battlify.app/buy")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.batteryblock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battlify").font(.title2.weight(.semibold))
                    Text(license.statusText)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                }
            }

            Divider()

            switch license.state {
            case .licensed:
                licensedView
            default:
                activationView
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private var licensedView: some View {
        Text("Thanks for supporting Battlify — all features are unlocked.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Remove License", role: .destructive) { license.deactivate() }
        }
    }

    @ViewBuilder
    private var activationView: some View {
        if case .expired = license.state {
            Label("Your trial has ended. Enter a license key to keep using Battlify's controls.",
                  systemImage: "exclamationmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("You're on the free trial. Enter a license key any time to unlock permanently.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("License key").font(.caption).foregroundStyle(.secondary)
            TextField("Paste your license key", text: $license.enteredKey, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .font(.system(.callout, design: .monospaced))
        }

        if let err = license.lastError {
            Label(err, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Link("Buy a license", destination: buyURL)
                .font(.callout)
            Spacer()
            Button("Activate") { license.activate() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var statusColor: Color {
        switch license.state {
        case .licensed: return .green
        case .trial: return .secondary
        case .expired: return .orange
        }
    }
}
