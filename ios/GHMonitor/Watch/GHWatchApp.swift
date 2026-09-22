import SwiftUI

@main
struct GHWatchApp: App {
    @StateObject private var workout = WorkoutManager()
    @StateObject private var motion = MotionRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workout)
                .environmentObject(motion)
        }
    }
}
