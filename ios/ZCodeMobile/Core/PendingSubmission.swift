import Foundation
import CryptoKit

struct PendingSubmission: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var draftKey: String
    var sessionID: String?
    var creation: [String: JSONValue]?
    var text: String
    var attachments: [Attachment]
    var uploadedIDs: [String: String] = [:]
    var createdAt = Date()

    func matches(text: String, attachments: [Attachment]) -> Bool {
        self.text == text && self.attachments == attachments
    }
}

/// Writes the immutable request before network transmission. Credentials never enter this file.
struct SubmissionJournal {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingSubmissions", isDirectory: true)
    }

    private func file(_ scope: String) -> URL {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    func read(scope: String) throws -> [String: PendingSubmission] {
        let url = file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: PendingSubmission].self, from: Data(contentsOf: url))
    }

    func write(_ values: [String: PendingSubmission], scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        try data.write(to: file(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = file(scope)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try url.setResourceValues(resources)
    }
}
