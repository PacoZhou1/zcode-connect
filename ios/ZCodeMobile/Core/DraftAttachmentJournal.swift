import Foundation
import CryptoKit

enum DraftAttachmentJournalFailure: LocalizedError, Equatable {
    case corruptRecord
    case unsupportedVersion(Int)
    case scopeMismatch
    case oversizedRecord
    case invalidAttachments

    var errorDescription: String? {
        switch self {
        case .corruptRecord: "附件草稿记录无法读取，原文件已保留。"
        case .unsupportedVersion: "附件草稿使用尚不支持的格式，原文件已保留。"
        case .scopeMismatch: "附件草稿与当前电脑或任务不匹配，原文件已保留。"
        case .oversizedRecord: "附件草稿记录超过容量限制，原文件已保留。"
        case .invalidAttachments: "附件草稿数据无效，请检查文件数量、大小和名称。"
        }
    }
}

/// Local, unsent attachment bytes. Each host scope and draft key has its own record.
/// The actor serializes filesystem access away from the main actor. Callers must
/// preserve their own edit ordering and only apply reads to the originating scope.
actor DraftAttachmentJournal {
    private struct Record: Codable {
        let version: Int
        let scopeDigest: String
        let draftDigest: String
        let attachments: [Attachment]
    }

    private static let formatVersion = 1
    private static let maximumCount = 6
    private static let maximumAttachmentBytes = 8 * 1024 * 1024
    private static let maximumEncodedBytes = maximumCount * maximumAttachmentBytes / 3 * 4 + 1024 * 1024

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DraftAttachments", isDirectory: true)
    }

    func read(scope: String, draftKey: String) throws -> [Attachment] {
        let url = file(scope: scope, draftKey: draftKey)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain,
               (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
                return []
            }
            throw error
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DraftAttachmentJournalFailure.corruptRecord
        }
        guard let size = values.fileSize, size <= Self.maximumEncodedBytes else {
            throw DraftAttachmentJournalFailure.oversizedRecord
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumEncodedBytes else { throw DraftAttachmentJournalFailure.oversizedRecord }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw DraftAttachmentJournalFailure.corruptRecord }
        guard record.version == Self.formatVersion else { throw DraftAttachmentJournalFailure.unsupportedVersion(record.version) }
        guard record.scopeDigest == digest(scope), record.draftDigest == digest(draftKey) else {
            throw DraftAttachmentJournalFailure.scopeMismatch
        }
        do { try validate(record.attachments) }
        catch { throw DraftAttachmentJournalFailure.corruptRecord }
        return record.attachments
    }

    /// Writing an empty array clears a valid draft atomically. An unreadable,
    /// oversized or newer-format record is never silently replaced, even by [].
    func write(_ attachments: [Attachment], scope: String, draftKey: String) throws {
        try validate(attachments)
        _ = try read(scope: scope, draftKey: draftKey)
        let record = Record(version: Self.formatVersion, scopeDigest: digest(scope),
                            draftDigest: digest(draftKey), attachments: attachments)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumEncodedBytes else { throw DraftAttachmentJournalFailure.oversizedRecord }
        let url = file(scope: scope, draftKey: draftKey)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try excludeFromBackup(directory)
        try excludeFromBackup(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try excludeFromBackup(url)
    }

    private func file(scope: String, draftKey: String) -> URL {
        directory.appendingPathComponent(digest(scope), isDirectory: true)
            .appendingPathComponent(digest(draftKey) + ".json")
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ attachments: [Attachment]) throws {
        guard attachments.count <= Self.maximumCount,
              Set(attachments.map(\.id)).count == attachments.count,
              attachments.allSatisfy({
                  !$0.id.isEmpty && $0.id.utf8.count <= 4096 &&
                  !$0.name.isEmpty && $0.name.utf8.count <= 4096 &&
                  !$0.mimeType.isEmpty && $0.mimeType.utf8.count <= 512 &&
                  !$0.data.isEmpty && $0.data.count <= Self.maximumAttachmentBytes
              }) else { throw DraftAttachmentJournalFailure.invalidAttachments }
    }

    private func excludeFromBackup(_ location: URL) throws {
        var url = location
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
