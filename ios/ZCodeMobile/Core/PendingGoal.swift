import Foundation
import CryptoKit

struct PendingGoal: Codable, Equatable {
    var id = UUID().uuidString
    var text: String
    var sessionID: String?
    var creation: [String: JSONValue]?
    var rejected = false
}

/// Keeps the same creation and command identities through a lost acknowledgement.
struct GoalSubmissionJournal {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingGoals", isDirectory: true)
    }
    private func file(_ scope: String) -> URL {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    func read(scope: String) throws -> [String: PendingGoal] {
        let url = file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: PendingGoal].self, from: Data(contentsOf: url))
    }
    func set(_ value: PendingGoal?, key: String, scope: String) throws {
        var values = try read(scope: scope)
        values[key] = value
        try write(values, scope: scope)
    }
    func write(_ values: [String: PendingGoal], scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = file(scope)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try url.setResourceValues(resources)
    }
}
