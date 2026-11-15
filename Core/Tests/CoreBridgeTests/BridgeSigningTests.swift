import XCTest
import CryptoKit
@testable import CoreBridge

final class BridgeSigningTests: XCTestCase {
    private let batch = BridgeBatch(summary: "test", ops: [.createCategory(name: "Gifts", kind: .expense, parent: nil)])

    func test_aBatchSignedByAPairedKeyIsVerified() throws {
        let key = P256.Signing.PrivateKey()
        let envelope = try BridgeSigning.seal(batch, with: key)
        let opened = try BridgeSigning.open(envelope, trusted: [BridgeSigning.keyId(key.publicKey): key.publicKey])
        XCTAssertEqual(opened.batch, batch)
        XCTAssertEqual(opened.sender, .verified(keyId: BridgeSigning.keyId(key.publicKey)))
    }

    func test_unsignedOrUnknownKeys_openUnverified() throws {
        let unsigned = try BridgeSigning.open(BridgeSigning.seal(batch, with: nil), trusted: [:])
        XCTAssertEqual(unsigned.sender, .unverified)
        let stranger = P256.Signing.PrivateKey()
        let unknown = try BridgeSigning.open(BridgeSigning.seal(batch, with: stranger), trusted: [:])
        XCTAssertEqual(unknown.sender, .unverified)
    }

    func test_alteredPayloadsAndCopiedKeyIds_areRejected() throws {
        let key = P256.Signing.PrivateKey()
        let trusted = [BridgeSigning.keyId(key.publicKey): key.publicKey]
        var tampered = try BridgeSigning.seal(batch, with: key)
        let edited = BridgeBatch(id: batch.id, createdAt: batch.createdAt, summary: "test",
                                 ops: [.deleteRule(ruleId: UUID())])
        tampered.payload = try BridgeCoding.encoder().encode(edited)
        XCTAssertThrowsError(try BridgeSigning.open(tampered, trusted: trusted)) {
            XCTAssertEqual($0 as? BridgeEnvelopeError, .badSignature(keyId: BridgeSigning.keyId(key.publicKey)))
        }

        // Someone else's key claiming the paired key's id.
        var forged = try BridgeSigning.seal(batch, with: P256.Signing.PrivateKey())
        forged.keyId = BridgeSigning.keyId(key.publicKey)
        XCTAssertThrowsError(try BridgeSigning.open(forged, trusted: trusted))
    }

    func test_undoOnlyOpsAndMismatchedIds_neverComeThroughTheInbox() throws {
        let undo = BridgeBatch(summary: "", ops: [.deleteCategory(id: UUID())])
        XCTAssertThrowsError(try BridgeSigning.open(BridgeSigning.seal(undo, with: nil), trusted: [:])) {
            XCTAssertEqual($0 as? BridgeEnvelopeError, .undoOnlyOp("deleteCategory"))
        }
        var swapped = try BridgeSigning.seal(batch, with: nil)
        swapped.id = UUID()
        XCTAssertThrowsError(try BridgeSigning.open(swapped, trusted: [:])) {
            XCTAssertEqual($0 as? BridgeEnvelopeError, .idMismatch)
        }
    }

    func test_fingerprintIsTheKeyIdGrouped_andThePublishedKeyRoundTrips() throws {
        let key = P256.Signing.PrivateKey()
        let published = BridgeSigning.publish(key, label: "Mac")
        XCTAssertEqual(published.keyId.count, 16)
        XCTAssertEqual(BridgeSigning.fingerprint(key.publicKey).replacingOccurrences(of: " ", with: "").lowercased(), published.keyId)
        XCTAssertEqual(BridgeSigning.keyId(try BridgeSigning.publicKey(published)), published.keyId)
    }
}
