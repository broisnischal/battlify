import Foundation

/// Result of verifying a license key with Gumroad.
public struct GumroadResult: Sendable, Equatable {
    public let valid: Bool
    public let email: String?
    public let refunded: Bool
    public let disputed: Bool
    public let uses: Int

    /// A key is "good" only if Gumroad says success and it wasn't refunded/charged back.
    public var isEntitled: Bool { valid && !refunded && !disputed }
}

public enum GumroadError: Error, CustomStringConvertible {
    case network
    case notFound          // bad key / wrong product
    case decoding

    public var description: String {
        switch self {
        case .network: return "Couldn't reach the license server. Check your connection."
        case .notFound: return "That license key isn't valid for Battlify."
        case .decoding: return "Unexpected response from the license server."
        }
    }
}

/// Verifies Battlify license keys against Gumroad's license API — the same model
/// Mac Mouse Fix uses. Keys are issued by Gumroad on purchase (Apple Pay etc.).
///
///   POST https://api.gumroad.com/v2/licenses/verify
///        product_id / product_permalink, license_key, increment_uses_count
public enum Gumroad {
    /// Your Gumroad product permalink (the slug in the product URL,
    /// e.g. "battlify" for gumroad.com/l/battlify). Set this for production.
    public static let productPermalink = "battlify"

    public static func verify(licenseKey: String,
                              productPermalink: String = productPermalink,
                              incrementUses: Bool = false) async throws -> GumroadResult {
        var req = URLRequest(url: URL(string: "https://api.gumroad.com/v2/licenses/verify")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let body = "product_permalink=\(enc(productPermalink))"
            + "&license_key=\(enc(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)))"
            + "&increment_uses_count=\(incrementUses ? "true" : "false")"
        req.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw GumroadError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Gumroad returns 404 for unknown keys.
        if status == 404 { return GumroadResult(valid: false, email: nil, refunded: false, disputed: false, uses: 0) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GumroadError.decoding
        }
        let success = (json["success"] as? Bool) ?? false
        let uses = (json["uses"] as? Int) ?? 0
        let purchase = json["purchase"] as? [String: Any]
        let email = purchase?["email"] as? String
        let refunded = (purchase?["refunded"] as? Bool) ?? false
        let disputed = ((purchase?["disputed"] as? Bool) ?? false)
            || ((purchase?["chargebacked"] as? Bool) ?? false)

        return GumroadResult(valid: success, email: email,
                             refunded: refunded, disputed: disputed, uses: uses)
    }
}
