import SwiftUI

struct LicenseView: View {
    @EnvironmentObject private var license: LicenseManager

    // Your store's checkout page (it mints an Ed25519 license key on purchase).
    private let buyURL = URL(string: "https://battlify.app/buy")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.batteryblock")
                    .font(.largeTitle).foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battlify").font(.title2.weight(.semibold))
                    Text(license.statusText).font(.callout).foregroundStyle(.secondary)
                }
            }

            Divider()

            if case .licensed = license.state {
                licensedView
            } else {
                pricingView
                activationView
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    // MARK: - Licensed

    @ViewBuilder
    private var licensedView: some View {
        Text("Thanks for buying Battlify — every feature is unlocked.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Remove License", role: .destructive) { license.deactivate() }
        }
    }

    // MARK: - Pricing

    private var pricingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            pricePoint(icon: "gift", tint: .secondary, title: "Free for 30 days",
                       body: "Your free days are only used up when you actually use Battlify — so you get the most out of them, stress-free.")
            pricePoint(icon: "checkmark.seal", tint: .secondary, title: "$2.99 to own",
                       body: "One-time payment, no subscriptions. Quick checkout — pay with Apple Pay.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pricePoint(icon: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Activation

    @ViewBuilder
    private var activationView: some View {
        if case .expired = license.state {
            Label("Your 30 free days are up. Buy Battlify to keep using its controls.",
                  systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !license.deviceCode.isEmpty {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your device code — enter it at checkout")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(license.deviceCode)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(license.deviceCode, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Already bought it? Enter your license key")
                .font(.caption).foregroundStyle(.secondary)
            TextField("XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX",
                      text: $license.enteredKey, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .font(.system(.callout, design: .monospaced))
                .disabled(license.verifying)
        }

        if let err = license.lastError {
            Label(err, systemImage: "xmark.octagon")
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Link("Buy Battlify — $2.99", destination: buyURL)
                .font(.callout.weight(.medium))
            Spacer()
            if license.verifying {
                ProgressView().controlSize(.small)
            }
            Button("Activate") { license.activate() }
                .keyboardShortcut(.defaultAction)
                .disabled(license.verifying)
        }
    }
}
