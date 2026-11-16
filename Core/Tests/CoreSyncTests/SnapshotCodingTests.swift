import XCTest
import Foundation
@testable import CoreModel
@testable import CoreSync

// The Claude bridge ships these snapshots as JSON (docs/decisions.md D13), so they must
// survive an encode/decode unchanged, money and clocks included.
final class SnapshotCodingTests: XCTestCase {
    private func roundTrip<T: SyncSnapshot>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    func test_everySnapshotType_roundTrips() throws {
        try roundTrip(Build.connection())
        try roundTrip(Build.accountGroup())
        try roundTrip(Build.accountSpace())
        try roundTrip(Build.account())
        try roundTrip(Build.category())
        try roundTrip(Build.categoryRule())
        try roundTrip(Build.transferRoute())
        try roundTrip(Build.transferGroup())
        try roundTrip(Build.budget())
        try roundTrip(Build.fxRate())
        try roundTrip(Build.transaction())
        try roundTrip(Build.sharedExpenseGroup())
        try roundTrip(Build.portfolioValuation())
        try roundTrip(Build.fundTrade())
        try roundTrip(Build.syncRun())
    }

    // A bridge file written before the broker cash anchor existed still decodes.
    func test_accountJSONWithoutBrokerCashAnchor_decodesAsNil() throws {
        let snap = Build.account()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)) as? [String: Any])
        json["brokerCashAnchorEur"] = nil
        json["brokerCashAnchorAt"] = nil
        let decoded = try JSONDecoder().decode(AccountSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.brokerCashAnchorEur)
        XCTAssertNil(decoded.brokerCashAnchorAt)
        XCTAssertEqual(decoded.id, snap.id)
    }

    func test_decimalAmounts_andSubSecondDates_areExact() throws {
        let amounts = ["0.1", "-31.99", "1234567.89", "0.06033031", "-0.01", "99999999.9999"]
        for raw in amounts {
            let amount = Decimal(string: raw)!
            let tx = TransactionSnapshot(
                id: UUID(), accountId: UUID(), externalId: "x",
                bookedAt: Date(timeIntervalSinceReferenceDate: 784_123_456.789_123),
                amount: amount, currency: "EUR", amountEur: amount, fxRateUsed: Decimal(string: "1.0832"),
                direction: .debit, categorySource: .manual, isTransfer: false,
                rawJSON: Data("{\"k\":\"v\"}".utf8),
                createdAt: .now, clock: .now)
            try roundTrip(tx)
        }
    }
}
