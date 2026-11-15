import Foundation

extension CoreLogic {
    // American Express Spain activity export (CSV, "Incluir todos los detalles de la operación").
    // Referencia is a stable per-row id, so no content-derived key is needed. Charges are
    // positive in Importe; the app stores debits negative.
    public enum AmexCSV {
        static let requiredColumns = ["Fecha", "Descripción", "Importe", "Referencia"]

        static func parse(_ records: [[String]]) throws -> StatementCSV.Parsed {
            var records = records
            guard !records.isEmpty else { throw StatementCSV.ParseError.missingColumns(requiredColumns) }
            let header = records.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            let missing = requiredColumns.filter { !header.contains($0) }
            guard missing.isEmpty else { throw StatementCSV.ParseError.missingColumns(missing) }
            func field(_ record: [String], _ name: String) -> String? {
                guard let i = header.firstIndex(of: name), i < record.count else { return nil }
                let value = record[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            var rows: [StatementCSV.Row] = []
            var errors: [String] = []
            for (i, record) in records.enumerated() {
                if record.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
                // The export wraps Referencia in single quotes so Excel keeps it as text.
                let reference = field(record, "Referencia")?.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                guard let reference, !reference.isEmpty,
                      let day = field(record, "Fecha"), let date = madridNoon.date(from: day + " 12:00"),
                      let importe = field(record, "Importe").flatMap(Transactions.parseSignedAmount) else {
                    errors.append("row \(i + 1): missing date, amount or reference")
                    continue
                }
                rows.append(StatementCSV.Row(
                    externalId: "amex:v1:\(reference)",
                    startedAt: date,
                    completedAt: nil,
                    amount: -importe,
                    description: field(record, "Descripción") ?? field(record, "Aparece en su Estado de Cuenta como"),
                    dateOnly: true))
            }
            return StatementCSV.Parsed(format: .amex, rows: rows, skippedTransfers: 0, errors: errors)
        }

        // Fecha has no time. Noon Madrid keeps the UTC day and sits within 12 hours of any
        // quick-add tapped that day, well inside the match window.
        private static let madridNoon = StatementCSV.formatter("dd/MM/yyyy HH:mm", tz: "Europe/Madrid")
    }
}
