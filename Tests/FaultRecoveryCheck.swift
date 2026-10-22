import Foundation
import BackupCore
import Darwin

private struct Request: Decodable {
    let mode: String
    let source: URL
    let destination: URL
    let planID: UUID
    let result: URL
    let restoreParent: URL
    let holdAfter: Int
    let marker: URL
    let release: URL
}

private final class Gate: @unchecked Sendable {
    var paused = false
}

@main enum FaultRecoveryCheck {
    static func main() throws {
        setbuf(stdout, nil)
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let engine = BackupEngine()
        var result: [String: Any] = ["mode": request.mode]
        do {
            switch request.mode {
            case "backup":
                let gate = Gate()
                let snapshot = try engine.backup(sources: [request.source], destination: request.destination, planID: request.planID, progress: { progress in
                    if request.holdAfter > 0 && progress.completed >= request.holdAfter && !gate.paused {
                        gate.paused = true
                        try! Data("paused after \(progress.completed)".utf8).write(to: request.marker, options: .atomic)
                        while !FileManager.default.fileExists(atPath: request.release.path) { usleep(10_000) }
                    }
                })
                result["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
            case "verify":
                let snapshots = try engine.snapshots(destination: request.destination, planID: request.planID)
                for snapshot in snapshots { try engine.verify(snapshotID: snapshot.id, destination: request.destination, planID: request.planID) }
                result["verifiedIDs"] = snapshots.map(\.id)
            case "restore":
                let snapshot = try engine.snapshots(destination: request.destination, planID: request.planID)[0]
                result["output"] = try engine.restore(snapshotID: snapshot.id, destination: request.destination, planID: request.planID, to: request.restoreParent).path
            default: preconditionFailure("Unknown fixture operation")
            }
            result["status"] = "pass"
        } catch {
            result["status"] = "error"
            result["error"] = error.localizedDescription
            result["domain"] = (error as NSError).domain
            result["code"] = (error as NSError).code
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: request.result, options: .atomic)
        print(String(decoding: data, as: UTF8.self))
        if result["status"] as? String == "error" { exit(2) }
    }
}
