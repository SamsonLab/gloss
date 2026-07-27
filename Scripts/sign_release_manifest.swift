#!/usr/bin/env swift

import CryptoKit
import Foundation

private let expectedPublicKey = Data(
    base64Encoded: "FtPLO0dyvSMP4BUSZtk4ROgObX6F2GAToLeNfOygcVY="
)!

private enum SigningError: LocalizedError {
    case usage
    case missingSigningKey
    case invalidSigningKey
    case unexpectedPublicKey
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: sign_release_manifest.swift <manifest-path> [signature-path]"
        case .missingSigningKey:
            "GLOSS_APP_UPDATE_MANIFEST_SIGNING_KEY is required."
        case .invalidSigningKey:
            "GLOSS_APP_UPDATE_MANIFEST_SIGNING_KEY must be a Base64-encoded Ed25519 private key."
        case .unexpectedPublicKey:
            "The manifest signing key does not match Gloss's pinned public key."
        case .invalidSignature:
            "Failed to create a 64-byte Ed25519 signature."
        }
    }
}

private func run() throws {
    let arguments = CommandLine.arguments.dropFirst()
    guard arguments.count == 1 || arguments.count == 2 else {
        throw SigningError.usage
    }

    let manifestURL = URL(fileURLWithPath: String(arguments[arguments.startIndex]))
    let signatureURL: URL
    if arguments.count == 2 {
        signatureURL = URL(fileURLWithPath: String(arguments[arguments.index(after: arguments.startIndex)]))
    } else {
        signatureURL = URL(fileURLWithPath: manifestURL.path + ".sig")
    }

    guard
        let encodedPrivateKey = ProcessInfo.processInfo.environment[
            "GLOSS_APP_UPDATE_MANIFEST_SIGNING_KEY"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !encodedPrivateKey.isEmpty
    else {
        throw SigningError.missingSigningKey
    }
    guard let privateKeyData = Data(base64Encoded: encodedPrivateKey) else {
        throw SigningError.invalidSigningKey
    }

    let privateKey: Curve25519.Signing.PrivateKey
    do {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    } catch {
        throw SigningError.invalidSigningKey
    }
    guard privateKey.publicKey.rawRepresentation == expectedPublicKey else {
        throw SigningError.unexpectedPublicKey
    }

    let manifestData = try Data(contentsOf: manifestURL)
    let signature = try privateKey.signature(for: manifestData)
    let publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: expectedPublicKey
    )
    guard signature.count == 64,
        publicKey.isValidSignature(signature, for: manifestData)
    else {
        throw SigningError.invalidSignature
    }

    try signature.base64EncodedData().write(to: signatureURL, options: .atomic)
}

do {
    try run()
} catch {
    fputs("sign_release_manifest.swift: \(error.localizedDescription)\n", stderr)
    exit(1)
}
