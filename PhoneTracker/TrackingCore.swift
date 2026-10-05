import Foundation

struct Fix: Equatable {
    var time: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var speed: Double?
    var speedAccuracy: Double?
    var altitude: Double?
    var bearing: Double?
    var rawLatitude: Double
    var rawLongitude: Double
    var rawSpeed: Double?
    var motion = "moving"

    init(time: Date, latitude: Double, longitude: Double, accuracy: Double, speed: Double? = nil,
         speedAccuracy: Double? = nil, altitude: Double? = nil, bearing: Double? = nil) {
        self.time = time; self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy
        self.speed = speed; self.speedAccuracy = speedAccuracy; self.altitude = altitude; self.bearing = bearing
        rawLatitude = latitude; rawLongitude = longitude; rawSpeed = speed
    }
}

struct TrackPoint: Identifiable, Equatable {
    let id: Int64
    let time: Date
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let speed: Double?
    let session: String
    let motion: String
}

func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let radians = Double.pi / 180
    let a = pow(sin((lat2 - lat1) * radians / 2), 2) + cos(lat1 * radians) * cos(lat2 * radians)
        * pow(sin((lon2 - lon1) * radians / 2), 2)
    return 12_742_000 * asin(sqrt(min(1, max(0, a))))
}

struct MotionDetector {
    private var samples: [Fix] = []
    private var state = "moving"
    private var anchor: Fix?
    private var resumeAt: Date?
    private var lastTime: Date?
    mutating func reset() { samples = []; state = "moving"; anchor = nil; resumeAt = nil }
    mutating func accept(_ point: Fix) -> String {
        if let lastTime, point.time.timeIntervalSince(lastTime) > 3 { reset() }
        lastTime = point.time
        guard let speed = point.rawSpeed, speed.isFinite, speed >= 0, point.accuracy <= 10 else {
            reset(); return "unknown"
        }
        let uncertainty = point.speedAccuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let movement = uncertainty.map { speed - $0 > 0.5 } ?? (speed > 1)
        let low = speed <= 1 && !movement && (uncertainty.map { $0 <= 1 } ?? (speed <= 0.3))
        if state == "stationary", let anchor {
            let departing = distance(anchor.rawLatitude, anchor.rawLongitude, point.rawLatitude, point.rawLongitude) > max(5, point.accuracy)
            if movement || departing {
                if resumeAt == nil { resumeAt = point.time }
                if point.time.timeIntervalSince(resumeAt!) >= 3 { reset(); return "moving" }
            } else {
                resumeAt = nil
                if !low { reset(); return "unknown" }
            }
            return state
        }
        guard low else { reset(); return movement ? "moving" : "unknown" }
        samples.append(point)
        while samples.count > 1 && point.time.timeIntervalSince(samples[1].time) >= 20 { samples.removeFirst() }
        let first = samples[0]
        let net = distance(first.rawLatitude, first.rawLongitude, point.rawLatitude, point.rawLongitude)
        let path = zip(samples, samples.dropFirst()).reduce(0.0) {
            $0 + distance($1.0.rawLatitude, $1.0.rawLongitude, $1.1.rawLatitude, $1.1.rawLongitude)
        }
        let clustered = samples.allSatisfy { distance(first.rawLatitude, first.rawLongitude, $0.rawLatitude, $0.rawLongitude) <= 5 }
        if !clustered || (net > 3 && path > 0 && net / path > 0.75) { reset(); return "moving" }
        let seconds = point.time.timeIntervalSince(first.time)
        state = seconds >= 20 ? "stationary" : seconds >= 15 ? "suspected_stationary" : "moving"
        if state == "stationary" { anchor = first }
        return state
    }
}

struct TrackingPipeline {
    private(set) var latest: Fix?
    private(set) var reason = "等待新定位"
    private var window: [Fix] = []
    private var detector = MotionDetector()
    private var locked: (Double, Double)?
    private var lastWrittenFix: Date?
    private var lastWriteUptime: TimeInterval?
    var interval: Int {
        guard let speed = latest?.rawSpeed, speed.isFinite, speed >= 0 else { return 30 }
        return speed > 20 / 3.6 ? 1 : speed > 10 / 3.6 ? 5 : 30
    }
    mutating func accept(_ sample: Fix, now: Date) -> Bool {
        func validCoordinate(_ value: Fix) -> Bool {
            value.latitude.isFinite && value.longitude.isFinite && abs(value.latitude) <= 90 && abs(value.longitude) <= 180
        }
        guard now.timeIntervalSince(sample.time) >= -1, now.timeIntervalSince(sample.time) <= 3 else {
            reason = "定位過期，等待新樣本"; return false
        }
        guard latest == nil || sample.time > latest!.time else { reason = "略過重複或倒序定位"; return false }
        guard validCoordinate(sample) else { reason = "定位座標無效"; return false }
        let fast = (sample.rawSpeed ?? 0) > 20 / 3.6
        guard sample.accuracy.isFinite, sample.accuracy >= 0,
              (fast ? sample.accuracy < 50 : sample.accuracy <= 30) else {
            reason = fast ? "等待合格定位（需 < 50 公尺）" : "等待合格定位（需 ≤ 30 公尺）"; return false
        }
        let dt = latest.map { sample.time.timeIntervalSince($0.time) } ?? 0
        if let previous = latest, dt <= 30,
           distance(previous.rawLatitude, previous.rawLongitude, sample.rawLatitude, sample.rawLongitude) > 70 * dt + previous.accuracy + sample.accuracy {
            reason = "略過不合理位置跳動"; return false
        }
        if latest == nil || dt > 3 { window = []; locked = nil }
        window.append(sample); if window.count > 3 { window.removeFirst() }
        let weighted = (sample.rawSpeed ?? 0) > 10 / 3.6 && window.count > 1
        var latitude = 0.0, offset = 0.0
        for (index, point) in window.enumerated() {
            let weight = weighted ? (index == window.count - 1 ? 0.9 : 0.1 / Double(window.count - 1)) : 1 / Double(window.count)
            latitude += point.latitude * weight
            offset += ((point.longitude - sample.longitude + 540).truncatingRemainder(dividingBy: 360) - 180) * weight
        }
        let longitude = (sample.longitude + offset + 540).truncatingRemainder(dividingBy: 360) - 180
        let state = detector.accept(sample)
        if state == "stationary" { if locked == nil { locked = (latitude, longitude) } } else { locked = nil }
        var result = sample
        result.latitude = locked?.0 ?? latitude; result.longitude = locked?.1 ?? longitude
        result.motion = state; if state == "stationary" { result.speed = 0 }
        latest = result; reason = "接收與平滑中"
        return true
    }
    func candidate(now: Date, uptime: TimeInterval) -> Fix? {
        guard let latest, now.timeIntervalSince(latest.time) <= 3,
              lastWrittenFix == nil || latest.time > lastWrittenFix! else { return nil }
        if let lastWriteUptime, uptime - lastWriteUptime < Double(interval) { return nil }
        return latest
    }
    mutating func written(_ fix: Fix, uptime: TimeInterval) { lastWrittenFix = fix.time; lastWriteUptime = uptime }
}

enum HistoryGeometry {
    static func segments(_ points: [TrackPoint], maxPoints: Int = 4000, maxSegments: Int = 120) -> [[TrackPoint]] {
        var groups: [[TrackPoint]] = [], previous: TrackPoint?
        for point in points {
            guard point.latitude.isFinite, point.longitude.isFinite, abs(point.latitude) <= 90, abs(point.longitude) <= 180 else {
                previous = nil; continue
            }
            if previous == nil || point.session != previous!.session || point.time.timeIntervalSince(previous!.time) > 120
                || point.time < previous!.time || abs(point.longitude - previous!.longitude) > 180 { groups.append([]) }
            groups[groups.count - 1].append(point); previous = point
        }
        let visible = Array(groups.suffix(maxSegments))
        if visible.reduce(0, { $0 + $1.count }) <= maxPoints { return visible }
        let mandatory = visible.reduce(0) { $0 + min(2, $1.count) }
        var available = max(0, maxPoints - mandatory), interior = visible.reduce(0) { $0 + max(0, $1.count - 2) }
        return visible.map { segment in
            let inner = max(0, segment.count - 2)
            let allocation = interior == 0 ? 0 : min(available, Int(ceil(Double(available) * Double(inner) / Double(interior))))
            available -= allocation; interior -= inner
            if segment.count <= allocation + 2 { return segment }
            return (0..<(allocation + 2)).map { segment[$0 * (segment.count - 1) / (allocation + 1)] }
        }
    }
}
