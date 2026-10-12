import Foundation
@main struct RelayHarness {
    static func main() async {
        let relay = TCPRelay(profileID: UUID())
        relay.onStatistics = { value in
            let object: [String: Any] = ["kind": "stats", "running": value.isRunning, "up": value.uploadBytes, "down": value.downloadBytes, "upRate": value.uploadRate, "downRate": value.downloadRate, "connections": value.activeConnections, "samples": value.samples.count, "history": value.samples.map { ["id": Double($0.id), "time": $0.time.timeIntervalSince1970, "up": $0.upload, "down": $0.download] }]
            print(String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
            fflush(stdout)
        }
        do {
            let targetPort = Int(CommandLine.arguments[1])!
            let requested = UInt16(CommandLine.arguments[2])!
            let operation = Task { try await relay.start(port: requested, target: LocalProxyEndpoint(host: "127.0.0.1", port: targetPort, protocol: .http, origin: .manual)) }
            if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "cancel" { operation.cancel() }
            let port = try await operation.value
            print("{\"kind\":\"ready\",\"port\":\(port)}"); fflush(stdout)
            _ = await Task.detached { readLine() }.value
            relay.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            let message: [String: String] = ["kind": "error", "detail": error.localizedDescription]
            print(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!); fflush(stdout); exit(1)
        }
    }
}
