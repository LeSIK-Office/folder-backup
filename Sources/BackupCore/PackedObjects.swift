import Foundation
import CryptoKit
import SQLite3
import Darwin

final class PackedObjects {
    static let maximumBytes: Int64 = 1_048_576
    static let filename = ".objects.sqlite"
    private var database: OpaquePointer?
    private var reading: OpaquePointer?
    private var writing: OpaquePointer?
    private var pending = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func open(at root: URL, create: Bool = false, immutable: Bool = false) throws -> PackedObjects? {
        let url = root.appendingPathComponent(filename)
        var attributes = stat()
        if !create && lstat(url.path, &attributes) != 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return try PackedObjects(url: url, create: create, immutable: immutable)
    }

    private init(url: URL, create: Bool, immutable: Bool) throws {
        for path in [url.path, url.path + "-journal", url.path + "-wal", url.path + "-shm"] {
            var s = stat()
            if lstat(path, &s) == 0, s.st_mode & S_IFMT != S_IFREG {
                throw BackupError.invalid(L10n.text("The packed storage path is not a regular file: %@", path))
            }
        }
        let flags = (create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW | (immutable ? SQLITE_OPEN_URI : 0)
        let path = immutable ? url.absoluteString + "?immutable=1" : url.path
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(database); database = nil; throw error
        }
        do {
            sqlite3_busy_timeout(database, 5000)
            if create {
                try execute("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE; CREATE TABLE IF NOT EXISTS objects (hash TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID")
                guard sqlite3_prepare_v2(database, "INSERT INTO objects(hash,data) VALUES(?,?)", -1, &writing, nil) == SQLITE_OK else { throw failure() }
            }
            guard sqlite3_prepare_v2(database, "SELECT data FROM objects WHERE hash=?", -1, &reading, nil) == SQLITE_OK else { throw failure() }
        } catch {
            sqlite3_finalize(reading); sqlite3_finalize(writing); sqlite3_close(database)
            reading = nil; writing = nil; database = nil
            throw error
        }
    }

    deinit {
        sqlite3_finalize(reading); sqlite3_finalize(writing)
        if pending > 0 { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        sqlite3_close(database)
    }

    private func failure() -> Error {
        if sqlite3_errcode(database) == SQLITE_FULL { return NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        if [SQLITE_CORRUPT, SQLITE_NOTADB].contains(sqlite3_errcode(database)) { return BackupError.corrupted(Self.filename) }
        return BackupError.invalid(L10n.text("Packed storage error: ") + String(cString: sqlite3_errmsg(database)))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func read(_ key: String) throws -> Data? {
        defer { sqlite3_reset(reading); sqlite3_clear_bindings(reading) }
        guard sqlite3_bind_text(reading, 1, key, -1, transient) == SQLITE_OK else { throw failure() }
        let result = sqlite3_step(reading)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        let count = Int(sqlite3_column_bytes(reading, 0))
        guard count <= Self.maximumBytes else { throw BackupError.corrupted(key) }
        let data = count == 0 ? Data() : Data(bytes: sqlite3_column_blob(reading, 0)!, count: count)
        guard String(SHA256.hash(data: data).description.suffix(64)) == key else { throw BackupError.corrupted(key) }
        return data
    }

    func put(_ data: Data, key: String) throws -> Bool {
        guard data.count <= Self.maximumBytes, String(SHA256.hash(data: data).description.suffix(64)) == key else { throw BackupError.corrupted(key) }
        if let existing = try read(key) {
            guard existing == data else { throw BackupError.corrupted(key) }
            return false
        }
        if pending == 0 { try execute("BEGIN IMMEDIATE") }
        defer { sqlite3_reset(writing); sqlite3_clear_bindings(writing) }
        guard sqlite3_bind_text(writing, 1, key, -1, transient) == SQLITE_OK else { throw failure() }
        let bound = data.withUnsafeBytes { buffer in
            data.isEmpty ? sqlite3_bind_zeroblob(writing, 2, 0) : sqlite3_bind_blob(writing, 2, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard bound == SQLITE_OK, sqlite3_step(writing) == SQLITE_DONE else { throw failure() }
        pending += 1
        if pending >= 256 { try flush() }
        return true
    }

    func flush() throws {
        if pending > 0 { try execute("COMMIT"); pending = 0 }
    }

    func remove(_ keys: Set<String>) throws {
        try flush()
        guard !keys.isEmpty else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM objects WHERE hash=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        try execute("BEGIN IMMEDIATE")
        do {
            for key in keys {
                guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try execute("PRAGMA incremental_vacuum")
    }

    func checkIntegrity() throws {
        try flush()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok" else { throw BackupError.corrupted(Self.filename) }
    }
}
