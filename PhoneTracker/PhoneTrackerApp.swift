import SwiftUI

@main
struct PhoneTrackerApp: App {
    @StateObject private var tracker = Tracker()
    var body: some Scene { WindowGroup { ContentView().environmentObject(tracker) } }
}
