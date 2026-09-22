import SwiftUI

@main
struct GHMonitorApp: App {
    @StateObject private var store: VitalsStore
    @StateObject private var evk: EVKManager
    @StateObject private var imu: IMUManager
    @StateObject private var watch = WatchLink()

    init() {
        let store = VitalsStore()
        let evk = EVKManager()
        let imu = IMUManager()
        store.imu = imu
        imu.onSamples = { [weak store] samples in store?.ingestIMU(samples) }
        _imu = StateObject(wrappedValue: imu)
        evk.onFrame = { [weak store] frame in store?.ingest(frame) }
        evk.onEvent = { [weak store] irq in store?.ingestEvent(irq) }
        evk.onStreamingStarted = { [weak store] in store?.resetSession() }
        _store = StateObject(wrappedValue: store)
        _evk = StateObject(wrappedValue: evk)
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            DemoFeed.start(store: store)
        }
    }

    var body: some Scene {
        WindowGroup {
            HealthMonitorView()
                .environmentObject(store)
                .environmentObject(evk)
                .environmentObject(imu)
                .environmentObject(watch)
        }
    }
}
