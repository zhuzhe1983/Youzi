import CryptoKit
import Foundation

// A fresh, disposable seed for this run. Never consult a keychain or release key.
let key = Curve25519.Signing.PrivateKey()
let seedURL = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedString().write(to: seedURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seedURL.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
