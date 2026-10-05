import SwiftUI
import CoreLocation

struct ContentView: View {
    @EnvironmentObject private var tracker: Tracker
    @Environment(\.scenePhase) private var phase
    @StateObject private var mapController = MapController()
    @StateObject private var exporter = MapExporter()
    @State private var historyMode = false
    @State private var navigation: [Bool] = []
    @State private var customRange = false
    @State private var backgroundHelp = false
    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if !navigation.isEmpty || historyMode {
                    Button("返回") {
                        historyMode = navigation.popLast() ?? false
                        tracker.playing = false
                    }.buttonStyle(.bordered)
                }
                Text("PhoneTracker").font(.title2.bold())
                Spacer()
            }
            Text("\(tracker.recording ? "● 記錄中" : "○") · \(tracker.status)")
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(tracker.recording ? "停止記錄" : "開始記錄") { tracker.recording ? tracker.stop() : tracker.start() }
                    .frame(maxWidth: .infinity)
                Button("背景執行") { tracker.prepareBackground(); backgroundHelp = true }
                    .disabled(!tracker.recording).frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
            HStack {
                tab("即時位置", selected: !historyMode) {
                    if historyMode { navigation.append(historyMode) }
                    historyMode = false; tracker.playing = false; mapController.follow()
                }
                tab("歷史軌跡", selected: historyMode) {
                    if !historyMode { navigation.append(historyMode) }
                    historyMode = true; tracker.refreshHistory(fit: true)
                }
                tab(exporter.busy ? "匯出中…" : "匯出地圖", selected: false) { exportMap() }
                    .disabled(exporter.busy || tracker.loading)
            }
            if historyMode {
                HStack(spacing: 5) {
                    ForEach([1, 3, 6], id: \.self) { hours in
                        tab("\(hours) 小時", selected: tracker.customStart == nil && tracker.hours == hours) { tracker.selectHours(hours) }
                    }
                    tab("指定起訖", selected: tracker.customStart != nil) { customRange = true }
                }
            }
            Text(detail).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            TrackingMap(tracker: tracker, controller: mapController, historyMode: historyMode)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if historyMode {
                Text(tracker.cursor.map { "標定時間 \(timeOnly($0.time)) · 長按三角形可拖動" } ?? "尚無歷史資料")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button(tracker.playing ? "暫停" : "播放") { tracker.togglePlayback() }.disabled(tracker.history.count < 2)
                    Slider(value: Binding(get: { playbackFraction }, set: { tracker.seek($0) }), in: 0...1)
                        .disabled(tracker.history.count < 2).accessibilityLabel("歷史回放時間")
                    Button("完整軌跡") { tracker.playing = false; tracker.playbackTime = nil }
                }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $customRange) {
            CustomRangeView(start: tracker.customStart ?? Date().addingTimeInterval(-Double(tracker.hours * 3600)),
                end: tracker.customEnd ?? Date()) { tracker.selectCustom(start: $0, end: $1) }
        }
        .sheet(item: $exporter.file) { ShareSheet(url: $0.url) }
        .alert("背景執行", isPresented: $backgroundHelp) {
            Button("定位權限設定") { tracker.openSettings() }
            Button("了解", role: .cancel) {}
        } message: {
            Text("記錄已啟動。請滑動返回主畫面或鎖屏，定位會繼續記錄。建議允許「永遠」定位並開啟「精確位置」。請勿從最近使用畫面強制關閉 App。")
        }
        .alert("提示", isPresented: Binding(get: { tracker.errorMessage != nil || exporter.error != nil }, set: {
            if !$0 { tracker.errorMessage = nil; exporter.error = nil }
        })) {
            Button("確定", role: .cancel) { tracker.errorMessage = nil; exporter.error = nil }
        } message: { Text(tracker.errorMessage ?? exporter.error ?? "") }
        .onReceive(refresh) { _ in if phase == .active && historyMode { tracker.refreshIfNeeded() } }
        .onChange(of: phase) { value in if value != .active { tracker.playing = false } }
    }
    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(selected ? Color.blue : Color.blue.opacity(0.08))
                .foregroundStyle(selected ? Color.white : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var detail: String {
        if historyMode {
            if tracker.loading { return "讀取歷史軌跡…" }
            return "\(dateTime(tracker.rangeStart)) 至 \(dateTime(tracker.rangeEnd))\n共 \(tracker.historyTotal) 筆" +
                (tracker.truncated ? " · 僅繪製最近 8,000 筆，完整記錄仍保留" : "")
        }
        guard let fix = tracker.latest else { return tracker.recording ? "等待合格定位 · 精度需 ≤ 30 m，高速需 < 50 m" : "請按「開始記錄」取得手機位置" }
        let speed = fix.speed.map { String(format: "%.1f km/h", $0 * 3.6) } ?? "速度未知"
        return "\(timeOnly(fix.time)) · 精度 \(Int(fix.accuracy)) m · \(speed)\n已保存 \(tracker.saved) 筆 · 間隔 \(tracker.interval) 秒"
    }
    private var playbackFraction: Double {
        guard let first = tracker.history.first, let last = tracker.history.last, last.time > first.time else { return 1 }
        return max(0, min(1, (tracker.playbackTime ?? last.time).timeIntervalSince(first.time) / last.time.timeIntervalSince(first.time)))
    }
    private func exportMap() {
        tracker.playing = false
        let segments = historyMode ? HistoryGeometry.segments(tracker.visibleHistory) : []
        let caption = "PhoneTracker · \(historyMode ? "歷史軌跡" : "即時位置")\n\(detail)" +
            (historyMode ? tracker.cursor.map { "\n標定時間 \(timeOnly($0.time))" } ?? "" : "")
        exporter.export(map: mapController.view, segments: segments, fix: historyMode ? nil : tracker.latest,
            cursor: historyMode ? tracker.cursor : nil, caption: caption)
    }
}

struct CustomRangeView: View {
    @Environment(\.dismiss) private var dismiss
    @State var start: Date
    @State var end: Date
    let apply: (Date, Date) -> Void
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("開始時間", selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("結束時間", selection: $end, displayedComponents: [.date, .hourAndMinute])
                Text("結束須晚於開始，最長 240 小時").font(.caption)
            }.navigationTitle("指定起訖")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("套用") { apply(start, end); dismiss() }
                            .disabled(end <= start || end.timeIntervalSince(start) > 240 * 3600)
                    }
                }
        }
    }
}
func timeOnly(_ date: Date) -> String { formatted(date, "HH:mm:ss") }
func dateTime(_ date: Date) -> String { formatted(date, "MM/dd HH:mm:ss") }
private func formatted(_ date: Date, _ pattern: String) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_TW"); formatter.dateFormat = pattern
    return formatter.string(from: date)
}
