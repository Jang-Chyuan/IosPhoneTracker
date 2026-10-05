import Foundation
import SQLite3

struct HistoryResult { let points: [TrackPoint]; let total: Int; let truncated: Bool }
struct StoreError: LocalizedError { let message: String; var errorDescription: String? { message } }

/// All access is serialized on Tracker's storage queue, including trim and queries.
final class LocationStore {
    static let maximumRecords = 80_000
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL? = nil) throws {
        let destination: URL
        if let url { destination = url } else {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("PhoneTracker", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            destination = directory.appendingPathComponent("phonetracker.sqlite")
        }
        guard sqlite3_open_v2(destination.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw error() }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS phone_locations (
              id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, location_at REAL NOT NULL,
              latitude REAL NOT NULL, longitude REAL NOT NULL, raw_latitude REAL NOT NULL, raw_longitude REAL NOT NULL,
              accuracy_meters REAL NOT NULL, altitude_meters REAL, speed_kmh REAL, raw_speed_kmh REAL,
              heading_degrees REAL, speed_accuracy_mps REAL, motion_state TEXT NOT NULL, session_id TEXT NOT NULL,
              display_latitude REAL NOT NULL, display_longitude REAL NOT NULL, display_source TEXT NOT NULL,
              display_location_at REAL NOT NULL)
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_phone_location_time ON phone_locations(recorded_at,id)")
        try execute(trimSQL)
    }
    deinit { sqlite3_close(db) }
    private var trimSQL: String {
        "DELETE FROM phone_locations WHERE id IN (SELECT id FROM phone_locations ORDER BY recorded_at DESC,id DESC LIMIT -1 OFFSET \(Self.maximumRecords))"
    }
    private func error() -> StoreError { StoreError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "無法開啟 SQLite") }
    private func execute(_ sql: String) throws { if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw error() } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }
    func save(_ fix: Fix, session: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let stmt = try statement("""
                INSERT INTO phone_locations(recorded_at,location_at,latitude,longitude,raw_latitude,raw_longitude,
                accuracy_meters,altitude_meters,speed_kmh,raw_speed_kmh,heading_degrees,speed_accuracy_mps,motion_state,
                session_id,display_latitude,display_longitude,display_source,display_location_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(stmt) }
            let numbers: [Double?] = [Date().timeIntervalSince1970, fix.time.timeIntervalSince1970, fix.latitude, fix.longitude,
                fix.rawLatitude, fix.rawLongitude, fix.accuracy, fix.altitude, fix.speed.map { $0 * 3.6 },
                fix.rawSpeed.map { $0 * 3.6 }, fix.bearing, fix.speedAccuracy]
            for (index, value) in numbers.enumerated() {
                if let value { sqlite3_bind_double(stmt, Int32(index + 1), value) } else { sqlite3_bind_null(stmt, Int32(index + 1)) }
            }
            sqlite3_bind_text(stmt, 13, fix.motion, -1, transient); sqlite3_bind_text(stmt, 14, session, -1, transient)
            sqlite3_bind_double(stmt, 15, fix.latitude); sqlite3_bind_double(stmt, 16, fix.longitude)
            sqlite3_bind_text(stmt, 17, "pipeline", -1, transient); sqlite3_bind_double(stmt, 18, fix.time.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
            try execute(trimSQL); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func range(start: Date, end: Date) throws -> HistoryResult {
        let countStmt = try statement("SELECT count(*) FROM phone_locations WHERE recorded_at>=? AND recorded_at<?")
        defer { sqlite3_finalize(countStmt) }
        sqlite3_bind_double(countStmt, 1, start.timeIntervalSince1970); sqlite3_bind_double(countStmt, 2, end.timeIntervalSince1970)
        guard sqlite3_step(countStmt) == SQLITE_ROW else { throw error() }
        let total = Int(sqlite3_column_int64(countStmt, 0))
        let stmt = try statement("""
            SELECT id,recorded_at,display_latitude,display_longitude,accuracy_meters,speed_kmh,session_id,motion_state
            FROM phone_locations WHERE recorded_at>=? AND recorded_at<? ORDER BY recorded_at DESC,id DESC LIMIT 8000
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970); sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
        var points: [TrackPoint] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            points.append(TrackPoint(id: sqlite3_column_int64(stmt, 0), time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                latitude: sqlite3_column_double(stmt, 2), longitude: sqlite3_column_double(stmt, 3), accuracy: sqlite3_column_double(stmt, 4),
                speed: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                session: String(cString: sqlite3_column_text(stmt, 6)), motion: String(cString: sqlite3_column_text(stmt, 7))))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw error() }
        return HistoryResult(points: Array(points.reversed()), total: total, truncated: total > 8000)
    }
}
