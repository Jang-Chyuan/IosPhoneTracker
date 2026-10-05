import Foundation
import Combine
import CoreLocation
import UIKit

final class Tracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var recording = false
    @Published private(set) var status = "尚未開始記錄"
    @Published private(set) var latest: Fix?
    @Published private(set) var saved = 0
    @Published private(set) var interval = 30
    @Published private(set) var authorization = CLAuthorizationStatus.notDetermined
    @Published private(set) var history: [TrackPoint] = []
    @Published private(set) var historyTotal = 0
    @Published private(set) var truncated = false
    @Published private(set) var loading = false
    @Published var errorMessage: String?
    @Published var cursor: TrackPoint?
    @Published var playbackTime: Date?
    @Published var playing = false
    @Published var hours = 6
    @Published var customStart: Date?
    @Published var customEnd: Date?
    @Published private(set) var rangeStart = Date().addingTimeInterval(-6 * 3600)
    @Published private(set) var rangeEnd = Date()
    @Published private(set) var mapRevision = 0
    private let manager = CLLocationManager()
    private let storageQueue = DispatchQueue(label: "PhoneTracker.sqlite")
    private var store: LocationStore?
    private var pipeline = TrackingPipeline()
    private var storageRecording = false
    private var session = UUID().uuidString
    private var storedCount = 0
    private var pendingStart = false
    private var historyVersion = 0
    private var lastQuery = Date.distantPast
    private var timer: AnyCancellable?
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        authorization = manager.authorizationStatus
        storageQueue.async { [weak self] in
            do { self?.store = try LocationStore() }
            catch { DispatchQueue.main.async { self?.errorMessage = "資料庫開啟失敗：\(error.localizedDescription)" } }
        }
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        if defaults.bool(forKey: "recording_enabled"), authorization == .authorizedAlways || authorization == .authorizedWhenInUse { start() }
    }
    func start() {
        guard !recording else { return }
        guard CLLocationManager.locationServicesEnabled() else { errorMessage = "請在 iPhone 設定中開啟定位服務"; return }
        switch manager.authorizationStatus {
        case .notDetermined: pendingStart = true; manager.requestWhenInUseAuthorization(); return
        case .denied, .restricted: errorMessage = "請到設定允許 PhoneTracker 使用定位"; return
        default: break
        }
        guard manager.accuracyAuthorization == .fullAccuracy else {
            errorMessage = "請到設定開啟「精確位置」，以取得合格定位"; return
        }
        defaults.set(true, forKey: "recording_enabled")
        recording = true; saved = 0; status = "等待合格定位"
        storageQueue.async { [weak self] in
            guard let self else { return }
            self.pipeline = TrackingPipeline(); self.session = UUID().uuidString
            self.storedCount = 0; self.storageRecording = true
        }
        manager.startUpdatingLocation()
    }
    func stop() {
        pendingStart = false; recording = false; playing = false
        defaults.set(false, forKey: "recording_enabled")
        manager.stopUpdatingLocation(); latest = nil; status = "已停止記錄"
        storageQueue.async { [weak self] in self?.storageRecording = false }
    }
    func prepareBackground() {
        guard recording else { errorMessage = "請先開始記錄"; return }
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .denied || authorization == .restricted { if recording { stop() }; pendingStart = false }
        else if pendingStart && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse) {
            pendingStart = false; start()
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = "定位暫時不可用：\(error.localizedDescription)"
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard recording else { return }
        let fixes = locations.map { location in
            Fix(time: location.timestamp, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy, speed: location.speed >= 0 ? location.speed : nil,
                speedAccuracy: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                bearing: location.course >= 0 ? location.course : nil)
        }
        storageQueue.async { [weak self] in
            guard let self, self.storageRecording else { return }
            for fix in fixes {
                let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
                guard self.pipeline.accept(fix, now: now) else {
                    let reason = self.pipeline.reason
                    DispatchQueue.main.async { if self.recording { self.status = reason } }
                    continue
                }
                var failure: String?
                if let candidate = self.pipeline.candidate(now: now, uptime: uptime) {
                    do {
                        guard let store = self.store else { throw StoreError(message: "資料庫尚未準備完成") }
                        try store.save(candidate, session: self.session)
                        self.pipeline.written(candidate, uptime: uptime); self.storedCount += 1
                    } catch { failure = "寫入失敗，下一個合格定位將重試" }
                }
                let latest = self.pipeline.latest, interval = self.pipeline.interval, count = self.storedCount
                let reason = failure ?? self.pipeline.reason
                DispatchQueue.main.async {
                    guard self.recording else { return }
                    self.latest = latest; self.interval = interval; self.saved = count; self.status = reason
                }
            }
        }
    }
    func selectHours(_ value: Int) {
        hours = value; customStart = nil; customEnd = nil; playbackTime = nil; playing = false; cursor = nil
        refreshHistory(fit: true)
    }
    func selectCustom(start: Date, end: Date) {
        guard end > start, end.timeIntervalSince(start) <= 240 * 3600 else {
            errorMessage = "結束須晚於開始，最長 240 小時"; return
        }
        customStart = start; customEnd = end; playbackTime = nil; playing = false; cursor = nil
        refreshHistory(fit: true)
    }
    func refreshHistory(fit: Bool = false) {
        historyVersion += 1
        let version = historyVersion
        let end = customEnd ?? Date(), start = customStart ?? end.addingTimeInterval(-Double(hours * 3600))
        loading = true; lastQuery = Date()
        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let store = self.store else { throw StoreError(message: "資料庫尚未準備完成") }
                let result = try store.range(start: start, end: end)
                DispatchQueue.main.async {
                    guard version == self.historyVersion else { return }
                    self.history = result.points; self.historyTotal = result.total; self.truncated = result.truncated
                    self.rangeStart = start; self.rangeEnd = end; self.loading = false
                    if fit { self.mapRevision += 1 }
                    if let cursor = self.cursor { self.cursor = result.points.first { $0.id == cursor.id } ?? result.points.first }
                    else { self.cursor = result.points.first }
                }
            } catch {
                DispatchQueue.main.async {
                    guard version == self.historyVersion else { return }
                    self.loading = false; self.errorMessage = "歷史讀取失敗：\(error.localizedDescription)"
                }
            }
        }
    }
    var visibleHistory: [TrackPoint] {
        guard let playbackTime else { return history }
        return history.filter { $0.time <= playbackTime }
    }
    func seek(_ fraction: Double) {
        guard let first = history.first, let last = history.last else { return }
        playing = false; playbackTime = first.time.addingTimeInterval(last.time.timeIntervalSince(first.time) * fraction)
        cursor = visibleHistory.last
    }
    func togglePlayback() {
        guard history.count > 1 else { return }
        if !playing && (playbackTime == nil || playbackTime! >= history.last!.time) { playbackTime = history.first!.time }
        playing.toggle()
    }
    private func tick() {
        if playing, let last = history.last {
            let next = (playbackTime ?? history[0].time).addingTimeInterval(60)
            playbackTime = min(next, last.time); cursor = visibleHistory.last
            if next >= last.time { playing = false }
        }
        if recording, let latest, Date().timeIntervalSince(latest.time) > 3 { status = "等待合格新定位；最後位置已過期" }
    }
    func refreshIfNeeded() {
        if !loading && !playing && playbackTime == nil && Date().timeIntervalSince(lastQuery) >= 10 { refreshHistory() }
    }
    func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
}
