import Foundation
import WatchConnectivity

/// Receives the CSV recordings the watch app sends (heart rate + high-rate motion) into Documents/WatchRecordings,
/// which is visible in the Files app (UIFileSharingEnabled) and shareable from the device sheet.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var status = "—"

    nonisolated static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchRecordings")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    override init() {
        super.init()
        refresh()
        guard WCSession.isSupported() else { status = "Watch link unsupported"; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refresh() {
        files = ((try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.status = activationState == .activated ? (session.isPaired ? "Watch paired" : "No watch paired") : "Not active" }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // the temporary file is deleted when this returns: move it synchronously
        let name = (file.metadata?["name"] as? String) ?? file.fileURL.lastPathComponent
        let dest = WatchLink.directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: file.fileURL, to: dest)
        Task { @MainActor in
            self.refresh()
            self.status = "Received \(name)"
        }
    }
}
