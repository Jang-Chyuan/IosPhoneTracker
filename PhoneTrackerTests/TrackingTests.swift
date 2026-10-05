import XCTest
import SQLite3
@testable import PhoneTracker

final class TrackingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private func fix(_ second: Double, speed: Double? = 0, accuracy: Double = 4, latitude: Double = 25) -> Fix {
        Fix(time: epoch.addingTimeInterval(second), latitude: latitude, longitude: 121, accuracy: accuracy, speed: speed)
    }
    func testSpeedBoundariesAndFreshWriteCadence() {
        for (kmh, interval) in [(0.0, 30), (10, 30), (10.1, 5), (20, 5), (20.1, 1), (60, 1)] {
            var pipeline = TrackingPipeline()
            var written: [Int] = []
            for second in 1...61 {
                let sample = fix(Double(second), speed: kmh / 3.6)
                XCTAssertTrue(pipeline.accept(sample, now: sample.time))
                XCTAssertEqual(pipeline.interval, interval)
                if let candidate = pipeline.candidate(now: sample.time, uptime: Double(second)) {
                    written.append(second); pipeline.written(candidate, uptime: Double(second))
                    XCTAssertNil(pipeline.candidate(now: sample.time, uptime: Double(second)))
                }
            }
            XCTAssertEqual(written, Array(stride(from: 1, through: 61, by: interval)))
            XCTAssertNil(pipeline.candidate(now: epoch.addingTimeInterval(100), uptime: 100))
        }
    }
    func testAccuracyStalenessAndJumpRejection() {
        var pipeline = TrackingPipeline()
        XCTAssertFalse(pipeline.accept(fix(1, accuracy: 31), now: epoch.addingTimeInterval(1)))
        XCTAssertFalse(pipeline.accept(fix(1), now: epoch.addingTimeInterval(5)))
        XCTAssertTrue(pipeline.accept(fix(6, accuracy: 30), now: epoch.addingTimeInterval(6)))
        XCTAssertFalse(pipeline.accept(fix(7, latitude: 26), now: epoch.addingTimeInterval(7)))
        var fast = TrackingPipeline()
        XCTAssertTrue(fast.accept(fix(1, speed: 60 / 3.6, accuracy: 49), now: epoch.addingTimeInterval(1)))
        XCTAssertFalse(fast.accept(fix(2, speed: 60 / 3.6, accuracy: 50), now: epoch.addingTimeInterval(2)))
    }
    func testStationaryLockAndDeparture() {
        var pipeline = TrackingPipeline()
        for second in 1...21 { let sample = fix(Double(second)); XCTAssertTrue(pipeline.accept(sample, now: sample.time)) }
        XCTAssertEqual(pipeline.latest?.motion, "stationary")
        for second in 22...25 {
            let sample = fix(Double(second), speed: 10, latitude: 25 + Double(second - 21) * 10 / 111_195)
            XCTAssertTrue(pipeline.accept(sample, now: sample.time))
            if second < 25 { XCTAssertEqual(pipeline.latest?.speed, 0) }
            XCTAssertEqual(pipeline.interval, 1) // Raw speed, even during stationary grace period.
        }
        XCTAssertEqual(pipeline.latest?.motion, "moving")
        XCTAssertEqual(pipeline.latest?.speed, 10)
    }
    func testHistoryDoesNotBridgeGapsOrSessions() {
        func point(_ id: Int64, _ seconds: Double, _ session: String) -> TrackPoint {
            TrackPoint(id: id, time: epoch.addingTimeInterval(seconds), latitude: 25, longitude: 121, accuracy: 4, speed: nil, session: session, motion: "moving")
        }
        let points = [point(1, 0, "a"), point(2, 30, "a"), point(3, 180, "a"), point(4, 181, "b")]
        XCTAssertEqual(HistoryGeometry.segments(points).map { $0.map(\.id) }, [[1, 2], [3], [4]])
    }
    func testSQLiteRetentionAndNewestHistoryWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let store = try LocationStore(url: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let seed = """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<80005)
            INSERT INTO phone_locations(recorded_at,location_at,latitude,longitude,raw_latitude,raw_longitude,
            accuracy_meters,motion_state,session_id,display_latitude,display_longitude,display_source,display_location_at)
            SELECT x,x,25,121,25,121,4,'moving','seed',25,121,'pipeline',x FROM n;
            """
        XCTAssertEqual(sqlite3_exec(db, seed, nil, nil, nil), SQLITE_OK)
        try store.save(fix(1), session: "new")
        let result = try store.range(start: Date(timeIntervalSince1970: 0), end: Date().addingTimeInterval(86400))
        XCTAssertEqual(result.total, 80_000); XCTAssertEqual(result.points.count, 8000); XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.points.last?.session, "new")
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT min(id),count(*) FROM phone_locations", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(stmt, 0), 7); XCTAssertEqual(sqlite3_column_int64(stmt, 1), 80_000)
    }
}
