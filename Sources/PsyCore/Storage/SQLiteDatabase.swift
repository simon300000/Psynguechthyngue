import Foundation
import SQLite3

final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    init(path: String, flags: Int32) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate SQLite connection"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw IndexedMetadataStoreError.sqlite(code: result, message: message)
        }
        handle = opened
        sqlite3_extended_result_codes(opened, 1)
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    func setBusyTimeout(milliseconds: Int32) throws {
        guard let handle else { throw IndexedMetadataStoreError.databaseClosed }
        let result = sqlite3_busy_timeout(handle, milliseconds)
        guard result == SQLITE_OK else { throw error(code: result) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw IndexedMetadataStoreError.databaseClosed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw IndexedMetadataStoreError.sqlite(code: result, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw IndexedMetadataStoreError.databaseClosed }
        return try SQLiteStatement(database: handle, sql: sql)
    }

    func scalarInt64(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        let result = try statement.step()
        switch result {
        case SQLITE_ROW:
            guard sqlite3_column_type(statement.handle, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement.handle, 0)
        case SQLITE_DONE:
            return nil
        default:
            throw error(code: result)
        }
    }

    func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        let result = try statement.step()
        switch result {
        case SQLITE_ROW:
            return statement.optionalText(at: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw error(code: result)
        }
    }

    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    func transaction<T>(mode: String = "IMMEDIATE", _ body: () throws -> T) throws -> T {
        try execute("BEGIN \(mode) TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func error(code: Int32? = nil) -> IndexedMetadataStoreError {
        guard let handle else { return .databaseClosed }
        return .sqlite(
            code: code ?? sqlite3_extended_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle))
        )
    }
}

final class SQLiteStatement {
    let handle: OpaquePointer
    private let database: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw IndexedMetadataStoreError.sqlite(
                code: result,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        handle = statement
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func reset() throws {
        let resetResult = sqlite3_reset(handle)
        guard resetResult == SQLITE_OK else { throw error(code: resetResult) }
        let clearResult = sqlite3_clear_bindings(handle)
        guard clearResult == SQLITE_OK else { throw error(code: clearResult) }
    }

    func bind(_ value: String, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(handle, index, pointer, -1, Self.transientDestructor)
        }
        guard result == SQLITE_OK else { throw error(code: result) }
    }

    func bind(_ value: String?, at index: Int32) throws {
        guard let value else {
            try bindNull(at: index)
            return
        }
        try bind(value, at: index)
    }

    func bind(_ value: Int64, at index: Int32) throws {
        let result = sqlite3_bind_int64(handle, index, value)
        guard result == SQLITE_OK else { throw error(code: result) }
    }

    func bind(_ value: Double, at index: Int32) throws {
        let result = sqlite3_bind_double(handle, index, value)
        guard result == SQLITE_OK else { throw error(code: result) }
    }

    func bind(_ value: Bool, at index: Int32) throws {
        try bind(Int64(value ? 1 : 0), at: index)
    }

    func bind(_ value: Data, at index: Int32) throws {
        let result: Int32
        if value.isEmpty {
            result = sqlite3_bind_zeroblob(handle, index, 0)
        } else {
            result = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), Self.transientDestructor)
            }
        }
        guard result == SQLITE_OK else { throw error(code: result) }
    }

    func bindNull(at index: Int32) throws {
        let result = sqlite3_bind_null(handle, index)
        guard result == SQLITE_OK else { throw error(code: result) }
    }

    @discardableResult
    func step() throws -> Int32 {
        let result = sqlite3_step(handle)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw error(code: result) }
        return result
    }

    func stepToCompletion() throws {
        let result = try step()
        guard result == SQLITE_DONE else {
            throw IndexedMetadataStoreError.sqlite(
                code: SQLITE_MISUSE,
                message: "statement unexpectedly produced rows"
            )
        }
    }

    func text(at column: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(handle, column) else {
            throw IndexedMetadataStoreError.invalidStoredValue("NULL text at column \(column)")
        }
        return String(cString: pointer)
    }

    func optionalText(at column: Int32) -> String? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL,
            let pointer = sqlite3_column_text(handle, column)
        else {
            return nil
        }
        return String(cString: pointer)
    }

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func bool(at column: Int32) -> Bool {
        sqlite3_column_int64(handle, column) != 0
    }

    func data(at column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let pointer = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    private func error(code: Int32) -> IndexedMetadataStoreError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
    }

    private static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
