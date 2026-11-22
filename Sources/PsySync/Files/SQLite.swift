import Foundation
import SQLite3

/// Minimal SQLite wrapper (ported from PsyCore/Storage/SQLiteDatabase.swift).
/// Not thread-safe by itself; `FilesStore` serialises access.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "sqlite(\(code)): \(message)" }
}

final class SQLiteConnection {
    private(set) var handle: OpaquePointer?
    private var statementCache: [String: SQLiteStatement] = [:]

    init(path: String, readOnly: Bool = false) throws {
        var opened: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open"
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteError(code: result, message: message)
        }
        handle = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 5_000)
    }

    deinit { close() }

    func close() {
        statementCache.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw SQLiteError(code: result, message: message)
        }
    }

    /// Cached prepared statement, reset and cleared before returning.
    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
        if let cached = statementCache[sql] {
            try cached.reset()
            return cached
        }
        let statement = try SQLiteStatement(database: handle, sql: sql)
        statementCache[sql] = statement
        return statement
    }

    func scalarInt64(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement.handle) }
        try statement.bind(bindings)
        guard try statement.step() == SQLITE_ROW, !statement.isNull(at: 0) else { return nil }
        return statement.int64(at: 0)
    }

    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement.handle) }
        try statement.bind(bindings)
        while try statement.step() == SQLITE_ROW {}
    }

    /// Resets every cached statement so no read transaction (WAL snapshot)
    /// stays open between calls — otherwise a later write from this
    /// connection fails with SQLITE_BUSY_SNAPSHOT after another process wrote.
    func resetStatements() {
        for statement in statementCache.values { sqlite3_reset(statement.handle) }
    }

    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    /// One read snapshot (WAL: fixed at the first read) for several
    /// statements, without taking the write lock.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        do {
            let value = try body()
            resetStatements()
            try execute("COMMIT")
            return value
        } catch {
            resetStatements()
            try? execute("ROLLBACK")
            throw error
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            resetStatements()
            try execute("COMMIT")
            return value
        } catch {
            resetStatements()
            try? execute("ROLLBACK")
            throw error
        }
    }
}

enum SQLiteValue {
    case text(String)
    case int(Int64)
    case real(Double)
    case blob(Data)
    case null

    static func bool(_ value: Bool) -> SQLiteValue { .int(value ? 1 : 0) }
    static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}

final class SQLiteStatement {
    let handle: OpaquePointer
    private let database: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(database)) + " in: " + sql)
        }
        handle = statement
    }

    deinit { sqlite3_finalize(handle) }

    func reset() throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = sqlite3_bind_text(handle, index, string, -1, Self.transient)
            case .int(let int):
                result = sqlite3_bind_int64(handle, index, int)
            case .real(let double):
                result = sqlite3_bind_double(handle, index, double)
            case .blob(let data):
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(handle, index, 0)
                } else {
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), Self.transient)
                    }
                }
            case .null:
                result = sqlite3_bind_null(handle, index)
            }
            guard result == SQLITE_OK else { throw error(result) }
        }
    }

    @discardableResult
    func step() throws -> Int32 {
        let result = sqlite3_step(handle)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw error(result) }
        return result
    }

    func text(at column: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(at column: Int32) -> String? {
        isNull(at: column) ? nil : text(at: column)
    }

    func int64(at column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(at column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func bool(at column: Int32) -> Bool { sqlite3_column_int64(handle, column) != 0 }

    func data(at column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let pointer = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func isNull(at column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(database)))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
