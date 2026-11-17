import Foundation

extension CoreLogic {
    // The Shortcuts action's answer: what the bank sync and the investment refresh did, then the
    // first thing in each that needs the user.
    public enum SyncSummary {
        public enum Banks: Equatable, Sendable {
            // No Enable Banking connection, so nothing to say about banks.
            case notConnected
            // Tried in the last 15 minutes, whether or not the banks answered.
            case recent
            case busy
            // Why the bank key couldn't be read, in a sentence.
            case noKey(String)
            case synced(EBSync.Report)
            // Still going when the action had to answer; it carries on in the background.
            case stillSyncing
        }

        public static func text(banks: Banks, investments: InvestmentRefresh.Outcome) -> String {
            var done: [String] = []
            var problems: [String] = []

            switch banks {
            case .notConnected:
                break
            case .recent:
                done.append("banks skipped (last tried under 15 minutes ago)")
            case .busy:
                done.append("banks already syncing")
            case .noKey(let problem):
                problems += ["Banks not synced", problem]
            case .stillSyncing:
                problems.append("Banks still syncing in the background; they finish next time if iOS stops them")
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

        // The action's answer at its deadline, from the steps done by then: investments run first,
        // so nil investments means nothing has finished.
        public static func soFar(banks: Banks?, investments: InvestmentRefresh.Outcome?) -> String {
            guard let investments else {
                return "Still refreshing in the background; it finishes next time if iOS stops it."
            }
            return text(banks: banks ?? .stillSyncing, investments: investments)
        }

        private static func count(_ n: Int, _ noun: String) -> String {
            n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
        }
    }
}
