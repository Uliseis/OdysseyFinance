import Foundation

extension CoreLogic {
    // The Shortcuts action's answer: what the bank sync and the investment refresh did, then the
    // first thing in each that needs the user.
    public enum SyncSummary {
        public enum Banks: Equatable, Sendable {
            // No Enable Banking connection, so nothing to say about banks.
            case notConnected
            // Synced in the last 15 minutes.
            case recent
            case busy
            case noKey(locked: Bool)
            case synced(EBSync.Report)
        }

        public static func text(banks: Banks, investments: InvestmentRefresh.Outcome) -> String {
            var done: [String] = []
            var problems: [String] = []

            switch banks {
            case .notConnected:
                break
            case .recent:
                done.append("banks synced in the last 15 minutes")
            case .busy:
                done.append("banks already syncing")
            case .noKey(let locked):
                problems += ["Banks not synced", locked
                    ? "The bank key can't be read while the iPhone is locked"
                    : "Add the Enable Banking key in Settings"]
            case .synced(let report):
                if report.synced > 0 {
                    let new = report.newTransactions > 0 ? ", \(count(report.newTransactions, "new transaction"))" : ""
                    done.append("banks synced (\(report.synced)\(new))")
                    problems += report.problems.prefix(1)
                } else if let first = report.problems.first {
                    problems += ["Banks not synced", first]
                }
            }

            if investments.liveAccounts > 0 {
                if !investments.updated.isEmpty {
                    done.append("investments refreshed (\(investments.updated.count))")
                    problems += investments.failures.prefix(1)
                } else if let first = investments.failures.first {
                    problems += ["Investments not refreshed", first]
                } else {
                    done.append("no new investment values")
                }
            }

            if done.isEmpty && problems.isEmpty {
                return "Nothing to sync: no bank or live-priced investment account is set up."
            }
            // Problems are left as written: a failure can start with an account's own name.
            let lead = done.joined(separator: ", ")
            let sentences = (lead.isEmpty ? [] : [lead.prefix(1).uppercased() + lead.dropFirst()]) + problems
            return sentences.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
        }

        private static func count(_ n: Int, _ noun: String) -> String {
            n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
        }
    }
}
