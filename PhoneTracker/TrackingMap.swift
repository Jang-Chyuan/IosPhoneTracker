import SwiftUI
import MapKit

final class MapController: ObservableObject {
    weak var view: MKMapView?
    @Published var followRevision = 0
    func follow() { followRevision += 1 }
}
final class PositionAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let cursor: Bool
    init(_ coordinate: CLLocationCoordinate2D, cursor: Bool) { self.coordinate = coordinate; self.cursor = cursor }
}

struct TrackingMap: UIViewRepresentable {
    @ObservedObject var tracker: Tracker
    @ObservedObject var controller: MapController
    let historyMode: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false; map.isPitchEnabled = false
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 121),
            span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)), animated: false)
        controller.view = map
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator; map.addGestureRecognizer(pan)
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        controller.view = map
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.mode != historyMode {
            coordinator.mode = historyMode; coordinator.routeKey = ""; coordinator.following = true
            map.removeOverlays(map.overlays); map.removeAnnotations(map.annotations)
            coordinator.position = nil; coordinator.cursor = nil
        }
        if coordinator.followRevision != controller.followRevision {
            coordinator.followRevision = controller.followRevision; coordinator.following = true; coordinator.liveTime = nil
        }
        if historyMode {
            let visible = tracker.visibleHistory
            let key = "\(visible.first?.id ?? 0):\(visible.last?.id ?? 0):\(visible.count)"
            if coordinator.routeKey != key {
                coordinator.routeKey = key
                map.removeOverlays(map.overlays)
                for segment in HistoryGeometry.segments(visible) {
                    let coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    if coordinates.count > 1 { map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count)) }
                    else if let coordinate = coordinates.first { map.addOverlay(MKCircle(center: coordinate, radius: 3)) }
                }
                coordinator.snapPoints = HistoryGeometry.segments(visible, maxPoints: 8000).flatMap { $0 }
            }
            if coordinator.fitRevision != tracker.mapRevision && !visible.isEmpty {
                coordinator.fitRevision = tracker.mapRevision
                var bounds = MKMapRect.null
                for point in visible {
                    let coordinate = MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                    bounds = bounds.union(MKMapRect(x: coordinate.x, y: coordinate.y, width: 1, height: 1))
                }
                if bounds.width < 2000 && bounds.height < 2000 { bounds = bounds.insetBy(dx: -1000, dy: -1000) }
                map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 45, left: 45, bottom: 45, right: 45), animated: false)
            }
            if !coordinator.dragging, let point = tracker.cursor, visible.contains(where: { $0.id == point.id }) {
                let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                if let cursor = coordinator.cursor { cursor.coordinate = coordinate }
                else { let cursor = PositionAnnotation(coordinate, cursor: true); coordinator.cursor = cursor; map.addAnnotation(cursor) }
            } else if visible.isEmpty, let cursor = coordinator.cursor { map.removeAnnotation(cursor); coordinator.cursor = nil }
        } else if let fix = tracker.latest {
            let coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
            if let position = coordinator.position { position.coordinate = coordinate }
            else { let position = PositionAnnotation(coordinate, cursor: false); coordinator.position = position; map.addAnnotation(position) }
            if coordinator.liveTime != fix.time {
                coordinator.liveTime = fix.time
                map.removeOverlays(map.overlays); map.addOverlay(MKCircle(center: coordinate, radius: fix.accuracy))
                if coordinator.following {
                    let span = map.region.span.latitudeDelta > 0.02 ? MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006) : map.region.span
                    map.setRegion(MKCoordinateRegion(center: coordinate, span: span), animated: true)
                }
            }
        } else {
            map.removeAnnotations(map.annotations); map.removeOverlays(map.overlays); coordinator.position = nil
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: TrackingMap
        var mode: Bool?
        var routeKey = "", following = true, dragging = false
        var followRevision = -1, fitRevision = -1
        var liveTime: Date?
        var position: PositionAnnotation?, cursor: PositionAnnotation?
        var snapPoints: [TrackPoint] = []
        init(_ parent: TrackingMap) { self.parent = parent }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) { if recognizer.state == .began { following = false } }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line); renderer.strokeColor = .systemBlue; renderer.lineWidth = 4; return renderer
            }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = .systemBlue; renderer.fillColor = UIColor.systemBlue.withAlphaComponent(mode == true ? 0.8 : 0.12)
                renderer.lineWidth = 1; return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let position = annotation as? PositionAnnotation else { return nil }
            let id = position.cursor ? "history-cursor" : "phone-position"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation; view.canShowCallout = false; view.isDraggable = position.cursor
            view.accessibilityLabel = position.cursor ? "歷史三角游標，長按可拖動" : "手機位置"
            view.image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                if position.cursor { drawTriangle(context.cgContext, at: CGPoint(x: 16, y: 30)) }
                else { UIColor.systemBlue.setFill(); UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 24, height: 24)).fill() }
            }
            view.centerOffset = CGPoint(x: 0, y: position.cursor ? -14 : 0)
            return view
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard let annotation = view.annotation as? PositionAnnotation, annotation.cursor else { return }
            if newState == .starting {
                dragging = true; parent.tracker.playing = false; view.dragState = .dragging
            } else if newState == .ending || newState == .canceling {
                let target = mapView.convert(annotation.coordinate, toPointTo: mapView)
                let chosen = snapPoints.min { a, b in
                    func squared(_ point: TrackPoint) -> CGFloat {
                        let screen = mapView.convert(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), toPointTo: mapView)
                        return pow(screen.x - target.x, 2) + pow(screen.y - target.y, 2)
                    }
                    return squared(a) < squared(b)
                }
                if let chosen {
                    parent.tracker.cursor = chosen
                    annotation.coordinate = CLLocationCoordinate2D(latitude: chosen.latitude, longitude: chosen.longitude)
                }
                dragging = false; view.dragState = .none
            }
        }
    }
}

func drawTriangle(_ context: CGContext, at tip: CGPoint) {
    context.saveGState()
    context.move(to: CGPoint(x: tip.x - 12, y: tip.y - 25))
    context.addLine(to: CGPoint(x: tip.x + 12, y: tip.y - 25)); context.addLine(to: tip); context.closePath()
    context.setFillColor(UIColor.systemOrange.cgColor); context.setStrokeColor(UIColor.white.cgColor)
    context.setLineWidth(2); context.drawPath(using: .fillStroke); context.restoreGState()
}
