import Foundation
import Observation

struct TrafficRateSample: Equatable, Sendable, Identifiable {
    let id: UInt64
    let time: Date
    let upload: Double
    let download: Double
}

struct TrafficSnapshot: Equatable, Sendable {
    let profileID: UUID
    var sessionID: UUID?
    var relayPort: UInt16?
    var sequence: UInt64 = 0
    var isRunning = false
    var uploadBytes: UInt64 = 0
    var downloadBytes: UInt64 = 0
    var uploadRate: Double = 0
    var downloadRate: Double = 0
    var activeConnections = 0
    var samples: [TrafficRateSample] = []
}

@MainActor @Observable
final class TrafficSessionModel {
    var snapshot: TrafficSnapshot
    init(profileID: UUID) { snapshot = TrafficSnapshot(profileID: profileID) }
}

@MainActor
final class TrafficStore {
    private var entries: [UUID: TrafficSessionModel] = [:]
    func session(for id: UUID) -> TrafficSessionModel {
        if let entry = entries[id] { return entry }
        let entry = TrafficSessionModel(profileID: id)
        entries[id] = entry
        return entry
    }
    func update(_ snapshot: TrafficSnapshot) { session(for: snapshot.profileID).snapshot = snapshot }
    func remove(_ id: UUID) { entries[id] = nil }
}

enum TrafficFormatting {
    static func rate(_ bytes: Double) -> String { format(max(0, bytes), units: ["B/s", "KB/s", "MB/s"]) }
    static func total(_ bytes: UInt64) -> String { format(Double(bytes) / 1024, units: ["KB", "MB", "GB"]) }
    private static func format(_ value: Double, units: [String]) -> String {
        var value = value; var index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, units[index])
    }
}
