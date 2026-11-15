import Foundation

extension CoreLogic {
    // What every statement parser produces. StatementImport only sees these types.
    public enum StatementCSV {
        public enum Format: Equatable, Sendable {
            case revolut
            case amex
        }

        public struct Row: Equatable, Sendable {
            public let externalId: String
            public let startedAt: Date
            public let completedAt: Date?
            public let amount: Decimal
            public let description: String?
            // The statement gives a day, not a time: startedAt is a placeholder.
            public var dateOnly = false
        }

        public struct Parsed: Equatable, Sendable {
            public var format: Format = .revolut
            public let rows: [Row]
            public let skippedTransfers: Int
            public var skippedNotCompleted = 0
            public let errors: [String]
        }

        public enum ParseError: Error, Equatable {
            case missingColumns([String])
        }

        // Only the Amex export has an "Importe" column. Anything else goes to the Revolut
        // parser, whose error names the columns it is missing.
        public static func parse(_ text: String) throws -> Parsed {
            let all = records(text)
            let header = all.first?.map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return header.contains("Importe") ? try AmexCSV.parse(all) : try RevolutCSV.parse(all)
        }

        // Minimal RFC 4180: quoted fields (which may span lines), doubled quotes, CRLF or LF.
        static func records(_ text: String) -> [[String]] {
            var records: [[String]] = []
            var fields: [String] = []
            var current = ""
            var inQuotes = false
            let chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if inQuotes {
                    if c == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" { current.append("\""); i += 1 }
                        else { inQuotes = false }
                    } else {
                        current.append(c)
                    }
                } else if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    fields.append(current); current = ""
                } else if c == "\n" || c == "\r" || c == "\r\n" {
                    fields.append(current); current = ""
                    records.append(fields); fields = []
                } else {
                    current.append(c)
                }
                i += 1
            }
            if !current.isEmpty || !fields.isEmpty {
                fields.append(current)
                records.append(fields)
            }
            return records
        }

        static func formatter(_ format: String, tz: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: tz)
            f.dateFormat = format
            return f
        }
    }
}
