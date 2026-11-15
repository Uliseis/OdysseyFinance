import XCTest
import Foundation
import SwiftData
import CloudKit
@testable import CoreModel
@testable import CoreSync

// A push builds on the cached system fields, which carry no data keys. A field cleared on
// the phone must still be in the pushed record's changedKeys, or CloudKit keeps the old
// value and the next server-to-local apply brings it back.
@MainActor
final class ClearedFieldSyncTests: XCTestCase {
    private let t0 = Build.epoch
    private let t1 = Build.epoch.addingTimeInterval(3_600)

    private func makeContext() throws -> ModelContext {
        let schema = Schema(CoreModelSchema.allTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    // CloudKit uploads only a record's changedKeys; this is the server applying them.
    private func serverApply(_ pushed: CKRecord, onto server: CKRecord) {
        for key in pushed.changedKeys() { server[key] = pushed[key] }
    }

    private func connection(id: UUID, lastError: String?, updatedAt: Date) -> ConnectionSnapshot {
        ConnectionSnapshot(
            id: id, connector: .enablebanking, institutionId: "INST", institutionName: "Test Bank",
            sessionId: "sess", accessTokenEnc: nil, refreshTokenEnc: nil, metadataJSON: nil,
            status: .active, expiresAt: nil, lastSyncAt: updatedAt, lastError: lastError,
            createdAt: Build.epoch, updatedAt: updatedAt)
    }

    func test_aClearedConnectionError_reachesTheServer_andSurvivesTheRoundTrip() throws {
        let ctx = try makeContext()
        let id = UUID()
        let server = RecordCoding.encode(connection(id: id, lastError: "Session status: CLOSED", updatedAt: t0))
        SyncRecordStore.store(server, in: ctx)
        ModelSnapshots.insertOrUpdate(connection(id: id, lastError: nil, updatedAt: t1), in: ctx)
        try ctx.save()

        let pushed = try XCTUnwrap(PushPipeline.buildRecord(for: SyncZone.recordID(for: id), in: ctx))
        serverApply(pushed, onto: server)
        XCTAssertEqual(server["lastSyncAt"] as? Date, t1)
        XCTAssertNil(server["lastError"])

        _ = try PullPipeline.apply(modifications: [server], deletions: [], in: ctx)
        XCTAssertNil(try XCTUnwrap(ModelSnapshots.find(connection: id, in: ctx)).lastError)
    }

    func test_uncategorizingAndUnpairing_reachTheServer() throws {
        let ctx = try makeContext()
        let account = Build.account()
        ModelSnapshots.insertOrUpdate(account, in: ctx)
        let id = UUID()
        let server = RecordCoding.encode(
            Build.transaction(id: id, accountId: account.id, categoryId: UUID(), categorySource: .rule, clock: t0))
        // The server still has the pairing the phone has since undone.
        server["transferGroupId"] = UUID().uuidString as CKRecordValue
        server["isTransfer"] = true as CKRecordValue
        SyncRecordStore.store(server, in: ctx)
        ModelSnapshots.insertOrUpdate(Build.transaction(id: id, accountId: account.id, categoryId: nil, clock: t1), in: ctx)
        try ctx.save()

        let pushed = try XCTUnwrap(PushPipeline.buildRecord(for: SyncZone.recordID(for: id), in: ctx))
        serverApply(pushed, onto: server)
        XCTAssertNil(server["categoryId"])
        XCTAssertNil(server["transferGroupId"])
        XCTAssertEqual(server["isTransfer"] as? Bool, false)
    }

    // The push conflict check compares clocks; each type stores its clock under its own key.
    func test_everyRecordTypeExposesItsClock() {
        func check<S: SyncSnapshot>(_ s: S, _ encode: (S) -> CKRecord) {
            let record = encode(s)
            XCTAssertEqual(RecordCoding.clock(of: record), s.clock, record.recordType)
        }
        check(Build.connection(updatedAt: t1), RecordCoding.encode)
        check(Build.accountGroup(updatedAt: t1), RecordCoding.encode)
        check(Build.accountSpace(updatedAt: t1), RecordCoding.encode)
        check(Build.account(clock: t1), RecordCoding.encode)
        check(Build.category(), RecordCoding.encode)
        check(Build.categoryRule(), RecordCoding.encode)
        check(Build.transferRoute(), RecordCoding.encode)
        check(Build.transferGroup(), RecordCoding.encode)
        check(Build.budget(), RecordCoding.encode)
        check(Build.fxRate(), RecordCoding.encode)
        check(Build.transaction(clock: t1), RecordCoding.encode)
        check(Build.sharedExpenseGroup(), RecordCoding.encode)
        check(Build.portfolioValuation(), RecordCoding.encode)
        check(Build.syncRun(startedAt: t1), RecordCoding.encode)
    }

    func test_onlyTheRepairPushSendsTiesToTheDevice() {
        XCTAssertTrue(ConflictResolver.localWinsPush(localClock: t1, remoteClock: t0, preferLocalOnTie: false))
        XCTAssertFalse(ConflictResolver.localWinsPush(localClock: t0, remoteClock: t0, preferLocalOnTie: false))
        XCTAssertTrue(ConflictResolver.localWinsPush(localClock: t0, remoteClock: t0, preferLocalOnTie: true))
        XCTAssertFalse(ConflictResolver.localWinsPush(localClock: t0, remoteClock: t1, preferLocalOnTie: true),
                       "a genuinely newer server copy still wins during the repair")
    }
}

