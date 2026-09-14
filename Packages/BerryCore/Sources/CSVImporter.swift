import BerryDriverKit
import Foundation

/// CSV → table import. Maps source columns
/// to table columns, generates batched multi-row INSERTs through the single
/// SQL path (N1), and runs the whole import in one transaction: any error rolls
/// everything back and is reported against the offending source line.
///
/// The happy path is batched for speed; on a batch error the importer replays
/// that batch row-by-row in a throwaway transaction to pinpoint the exact
/// failing line before returning.
public enum CSVImporter {
    public struct ColumnMapping: Sendable, Equatable {
        public let csvIndex: Int
        public let tableColumn: String
        public init(csvIndex: Int, tableColumn: String) {
            self.csvIndex = csvIndex
            self.tableColumn = tableColumn
        }
    }

    public struct Failure: Sendable, Equatable {
        public let line: Int
        public let message: String
    }

    public struct Result: Sendable, Equatable {
        public let insertedRows: Int
        public let failure: Failure?
    }

    /// Imports data records (header already stripped by the caller).
    public static func `import`(
        records: [CSVParser.Record],
        into table: TableRef,
        mapping: [ColumnMapping],
        treatEmptyAsNull: Bool = true,
        batchSize: Int = 100,
        on session: Session
    ) async throws -> Result {
        guard !records.isEmpty, !mapping.isEmpty else {
            return Result(insertedRows: 0, failure: nil)
        }
        let dialect = session.dialect
        let columns = mapping.map { dialect.quoteIdentifier($0.tableColumn) }.joined(separator: ", ")
        let target = dialect.qualifiedName(of: table)
        let useTransaction = session.capabilities.transactions

        func row(_ record: CSVParser.Record) -> [BerryValue] {
            mapping.map { column in
                let value = column.csvIndex < record.fields.count ? record.fields[column.csvIndex] : ""
                return value.isEmpty && treatEmptyAsNull ? .null : .text(value)
            }
        }

        func insertSQL(_ batch: ArraySlice<CSVParser.Record>) -> String {
            let tuples = batch
                .map { "(" + row($0).map(dialect.literal).joined(separator: ", ") + ")" }
                .joined(separator: ",\n  ")
            return "INSERT INTO \(target) (\(columns)) VALUES\n  \(tuples)"
        }

        func run(_ sql: String) async throws {
            for try await _ in QueryService.execute(sql, on: session, autoLimit: nil) {}
        }

        let size = max(1, batchSize)
        if useTransaction { try await run("BEGIN") }
        var index = 0
        do {
            while index < records.count {
                let batch = records[index..<min(index + size, records.count)]
                try await run(insertSQL(batch))
                index += batch.count
            }
            if useTransaction { try await run("COMMIT") }
            return Result(insertedRows: records.count, failure: nil)
        } catch {
            if useTransaction { try? await run("ROLLBACK") }
            let failedBatch = records[index..<min(index + size, records.count)]
            let failure = await pinpoint(failedBatch, insertSQL: insertSQL, run: run, useTransaction: useTransaction, fallback: error)
            return Result(insertedRows: 0, failure: failure)
        }
    }

    /// Replays a failed batch one record at a time to find the exact source
    /// line that errors; the throwaway transaction is always rolled back.
    private static func pinpoint(
        _ batch: ArraySlice<CSVParser.Record>,
        insertSQL: (ArraySlice<CSVParser.Record>) -> String,
        run: (String) async throws -> Void,
        useTransaction: Bool,
        fallback: Error
    ) async -> Failure {
        if useTransaction { try? await run("BEGIN") }
        var found: Failure?
        for record in batch {
            do {
                try await run(insertSQL(ArraySlice([record])))
            } catch {
                found = Failure(line: record.line, message: error.localizedDescription)
                break
            }
        }
        if useTransaction { try? await run("ROLLBACK") }
        // Could not reproduce per-row (e.g. a constraint only the batch trips):
        // report the batch's first line with the original error.
        return found ?? Failure(line: batch.first?.line ?? 0, message: fallback.localizedDescription)
    }
}
