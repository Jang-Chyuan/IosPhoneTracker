import SwiftUI
import MapKit

struct ExportFile: Identifiable { let id = UUID(); let url: URL }
final class MapExporter: ObservableObject {
    @Published var busy = false
    @Published var file: ExportFile?
    @Published var error: String?
    private var snapshotter: MKMapSnapshotter?
    func export(map: MKMapView?, segments: [[TrackPoint]], fix: Fix?, cursor: TrackPoint?, caption: String) {
        guard !busy else { return }
        guard let map, map.bounds.width > 0, map.bounds.height > 0 else { error = "請等待地圖載入完成"; return }
        busy = true
        let options = MKMapSnapshotter.Options()
        options.camera = map.camera.copy() as! MKMapCamera
        options.size = map.bounds.size; options.scale = UIScreen.main.scale
        options.mapType = map.mapType
        let job = MKMapSnapshotter(options: options)
        snapshotter = job
        job.start(with: .main) { [weak self] snapshot, failure in
            guard let self else { return }
            self.snapshotter = nil
            guard let snapshot else { self.busy = false; self.error = failure?.localizedDescription ?? "無法匯出地圖"; return }
            let font = UIFont.systemFont(ofSize: 13)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let width = snapshot.image.size.width
            let text = NSAttributedString(string: caption, attributes: attributes)
            let textHeight = ceil(text.boundingRect(with: CGSize(width: width - 24, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: snapshot.image.size.height + textHeight + 24)).image { output in
                let context = output.cgContext
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: snapshot.image.size.height + textHeight + 24)))
                snapshot.image.draw(at: .zero)
                context.saveGState()
                // Leave the bottom attribution strip untouched by custom route rendering.
                context.clip(to: CGRect(x: 0, y: 0, width: width, height: max(0, snapshot.image.size.height - 30)))
                for segment in segments {
                    guard let first = segment.first else { continue }
                    let initial = snapshot.point(for: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                    context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(4)
                    if segment.count == 1 {
                        context.setFillColor(UIColor.systemBlue.cgColor); context.fillEllipse(in: CGRect(x: initial.x - 3, y: initial.y - 3, width: 6, height: 6))
                    } else {
                        context.beginPath(); context.move(to: initial)
                        for point in segment.dropFirst() { context.addLine(to: snapshot.point(for: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))) }
                        context.strokePath()
                    }
                }
                if let fix {
                    let point = snapshot.point(for: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude))
                    let east = snapshot.point(for: CLLocationCoordinate2D(latitude: fix.latitude,
                        longitude: fix.longitude + fix.accuracy / (111_195 * max(0.01, abs(cos(fix.latitude * .pi / 180))))))
                    let radius = hypot(east.x - point.x, east.y - point.y)
                    context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.12).cgColor)
                    context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.5).cgColor)
                    context.setLineWidth(1)
                    context.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                    context.drawPath(using: .fillStroke)
                    context.setFillColor(UIColor.systemBlue.cgColor); context.fillEllipse(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
                }
                if let cursor { drawTriangle(context, at: snapshot.point(for: CLLocationCoordinate2D(latitude: cursor.latitude, longitude: cursor.longitude))) }
                context.restoreGState()
                text.draw(with: CGRect(x: 12, y: snapshot.image.size.height + 12, width: width - 24, height: textHeight), options: .usesLineFragmentOrigin, context: nil)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("map_exports", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                        if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                           Date().timeIntervalSince(date) > 7 * 86400 { try? FileManager.default.removeItem(at: old) }
                    }
                    let url = directory.appendingPathComponent("PhoneTracker-\(UUID().uuidString).png")
                    guard let data = image.pngData() else { throw StoreError(message: "無法產生 PNG") }
                    try data.write(to: url, options: .atomic)
                    DispatchQueue.main.async { self.busy = false; self.file = ExportFile(url: url) }
                } catch { DispatchQueue.main.async { self.busy = false; self.error = "匯出失敗：\(error.localizedDescription)" } }
            }
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
