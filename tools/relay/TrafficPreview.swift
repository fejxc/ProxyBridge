import SwiftUI
import AppKit

@main struct TrafficPreview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "build/relay-metrics-live.json"))) as! [String: Any]
        let profile = UUID()
        let session = TrafficSessionModel(profileID: profile)
        var value = TrafficSnapshot(profileID: profile, sessionID: UUID(), relayPort: 17997, isRunning: true)
        value.uploadBytes = (object["up"] as! NSNumber).uint64Value
        value.downloadBytes = (object["down"] as! NSNumber).uint64Value
        value.uploadRate = (object["upRate"] as! NSNumber).doubleValue
        value.downloadRate = (object["downRate"] as! NSNumber).doubleValue
        value.samples = (object["history"] as! [[String: NSNumber]]).map {
            TrafficRateSample(id: $0["id"]!.uint64Value, time: Date(timeIntervalSince1970: $0["time"]!.doubleValue), upload: $0["up"]!.doubleValue, download: $0["down"]!.doubleValue)
        }
        session.snapshot = value
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = TrafficStatsView(session: session, connected: true, initiallyExpanded: true)
                .padding(16).frame(width: 368)
                .background(scheme == .light ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.13))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Unable to render traffic card") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/traffic-\(name).png"))
        }
    }
}
