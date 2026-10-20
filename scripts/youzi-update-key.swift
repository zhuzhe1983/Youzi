#!/usr/bin/env swift
// Release-only key management. Private seeds never enter the app or Keychain.
import CryptoKit
import Darwin
import Foundation

enum KeyError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let message): return message }
    }
}

func readPrivateSeed(_ url: URL) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw KeyError.invalid("Cannot open private key file.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == geteuid(),
          (info.st_mode & 0o077) == 0,
          info.st_size > 0, info.st_size <= 128 else {
        throw KeyError.invalid("Private key must be an owner-only regular file (chmod 600).")
    }
    var bytes = [UInt8](repeating: 0, count: 129)
    let count = read(fd, &bytes, bytes.count)
    guard count > 0, count <= 128,
          let text = String(bytes: bytes.prefix(count), encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          seed.count == 32 else {
        throw KeyError.invalid("Private key must contain a base64-encoded 32-byte Ed25519 seed.")
    }
    return seed
}

func generateKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    var parentInfo = stat()
    guard lstat(parent.path, &parentInfo) == 0,
          (parentInfo.st_mode & S_IFMT) == S_IFDIR,
          parentInfo.st_uid == geteuid(),
          (parentInfo.st_mode & 0o077) == 0 else {
        throw KeyError.invalid("Create the key inside an owner-only directory (chmod 700).")
    }
    let key = Curve25519.Signing.PrivateKey()
    let payload = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
        throw KeyError.invalid("Cannot create private key. Existing files are never overwritten.")
    }
    var complete = false
    defer {
        close(fd)
        if !complete { unlink(url.path) }
    }
    let count = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard count == payload.count, fsync(fd) == 0 else {
        throw KeyError.invalid("Could not persist private key.")
    }
    complete = true
    return key
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 3, ["generate", "public-key"].contains(args[0]),
          args[1] == "--private-key-file", args[2].hasPrefix("/") else {
        throw KeyError.invalid(
            "Usage: youzi-update-key.swift generate|public-key --private-key-file /absolute/path"
        )
    }
    let url = URL(fileURLWithPath: args[2]).standardizedFileURL
    let key = try args[0] == "generate"
        ? generateKey(at: url)
        : Curve25519.Signing.PrivateKey(rawRepresentation: readPrivateSeed(url))
    // The only stdout output is the public key. Never print/export the seed.
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("Update signing key: \(error)\n".utf8))
    exit(1)
}
