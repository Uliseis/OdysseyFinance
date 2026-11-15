import Foundation
import CryptoKit

// What the Mac drops in bridge/inbox/. The batch bytes travel as-is so the signature covers
// exactly what was signed, with no re-encoding on the phone.
public struct BridgeEnvelope: Codable, Sendable, Equatable {
    public var id: UUID
    public var payload: Data
    public var keyId: String?
    public var signature: Data?
}

// A Mac's public key, published to bridge/keys/<keyId>.json for the phone to pair with.
public struct BridgePublicKey: Codable, Sendable, Equatable {
    public var keyId: String
    public var publicKey: Data
    public var createdAt: Date
    public var label: String
}

public enum BridgeSender: Sendable, Equatable {
    case verified(keyId: String)
    case unverified

    public var isVerified: Bool { if case .verified = self { true } else { false } }
}

public enum BridgeEnvelopeError: Error, CustomStringConvertible, Equatable {
    case badSignature(keyId: String)
    case idMismatch
    case undoOnlyOp(String)

    public var description: String {
        switch self {
        case .badSignature(let keyId): "The signature doesn't match the paired key \(keyId): the file was altered or forged"
        case .idMismatch: "The envelope and batch ids differ"
        case .undoOnlyOp(let op): "\(op) can only come from the phone's own undo"
        }
    }
}

// Auto-apply trusts only batches signed by a Mac key paired on the phone. Anything else
// (unsigned, unknown key) still opens the review sheet, marked unverified.
public enum BridgeSigning {
    public static func keyId(_ key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.x963Representation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // The same digest as keyId, grouped for reading aloud between screens.
    public static func fingerprint(_ key: P256.Signing.PublicKey) -> String {
        let hex = keyId(key).uppercased()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    public static func publish(_ key: P256.Signing.PrivateKey, label: String, now: Date = .now) -> BridgePublicKey {
        BridgePublicKey(keyId: keyId(key.publicKey), publicKey: key.publicKey.x963Representation, createdAt: now, label: label)
    }

    public static func seal(_ batch: BridgeBatch, with key: P256.Signing.PrivateKey?) throws -> BridgeEnvelope {
        let payload = try BridgeCoding.encoder().encode(batch)
        guard let key else { return BridgeEnvelope(id: batch.id, payload: payload) }
        return BridgeEnvelope(id: batch.id, payload: payload, keyId: keyId(key.publicKey),
                              signature: try key.signature(for: payload).derRepresentation)
    }

    public static func open(
        _ envelope: BridgeEnvelope, trusted: [String: P256.Signing.PublicKey]
    ) throws -> (batch: BridgeBatch, sender: BridgeSender) {
        var sender = BridgeSender.unverified
        if let keyId = envelope.keyId, let key = trusted[keyId] {
            guard let der = envelope.signature,
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
                  key.isValidSignature(signature, for: envelope.payload) else {
                throw BridgeEnvelopeError.badSignature(keyId: keyId)
            }
            sender = .verified(keyId: keyId)
        }
        let batch = try BridgeCoding.decoder().decode(BridgeBatch.self, from: envelope.payload)
        guard batch.id == envelope.id else { throw BridgeEnvelopeError.idMismatch }
        if let op = batch.ops.first(where: \.isUndoOnly) { throw BridgeEnvelopeError.undoOnlyOp(op.name) }
        return (batch, sender)
    }

    public static func publicKey(_ published: BridgePublicKey) throws -> P256.Signing.PublicKey {
        try P256.Signing.PublicKey(x963Representation: published.publicKey)
    }
}
