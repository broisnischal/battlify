import Foundation
import CryptoKit
import BattlifyKit

// Seller-side tool: generate the signing keypair and mint license tokens.
// NOT shipped in the app bundle. The private key must stay secret.
//
//   licensetool genkey
//   licensetool sign --priv <base64> --email a@b.com --name "A B" [--days 365]

let args = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args.first {
case "genkey":
    let priv = Curve25519.Signing.PrivateKey()
    print("PRIVATE KEY (keep secret, give to your license server):")
    print("  " + priv.rawRepresentation.base64EncodedString())
    print("PUBLIC KEY (paste into License.publicKeyBase64 in the app):")
    print("  " + priv.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard let priv = value("--priv"),
          let email = value("--email") else {
        FileHandle.standardError.write(Data(
            "usage: licensetool sign --priv <base64> --email <e> [--name <n>] [--days <n>]\n".utf8))
        exit(64)
    }
    let name = value("--name") ?? ""
    var expires: Date? = nil
    if let days = value("--days").flatMap({ Int($0) }) {
        expires = Date().addingTimeInterval(Double(days) * 86_400)
    }
    let info = LicenseInfo(email: email, name: name, issuedAt: Date(),
                           expiresAt: expires, product: License.product)
    do {
        let token = try License.sign(info, privateKeyBase64: priv)
        print(token)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

case "verify":
    guard let token = value("--token") else {
        FileHandle.standardError.write(Data("usage: licensetool verify --token <token>\n".utf8))
        exit(64)
    }
    // Verify against the public key embedded in the app.
    do {
        let info = try License.verify(token)
        print("VALID — \(info.name.isEmpty ? info.email : "\(info.name) <\(info.email)>")")
        print("  issued:  \(info.issuedAt)")
        print("  expires: \(info.expiresAt.map { "\($0)" } ?? "never")")
    } catch {
        print("INVALID — \(error)")
        exit(1)
    }

default:
    print("""
    licensetool — Battlify license keys

      genkey                              Generate an Ed25519 keypair
      sign --priv <b64> --email <e>       Mint a license token
           [--name <n>] [--days <n>]      (omit --days for a perpetual license)
      verify --token <token>             Verify a token against the app's public key
    """)
}
