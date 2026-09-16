import Foundation

struct MirrorConfig: Codable, Sendable {
    var token: String
    var port: UInt16 = 28800
    var captureTopCrop: Double = 30      // Simulator window title bar, calibrated via --probe-shot
    var width: Int = 886                 // destination encode width (iPhone 17 Pro Max @2x logical 443*2)
    var height: Int = 1920
    var fps: Int = 30
    var bitrate: Int = 1_200_000

    static func directory() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(".zcode-mirror", isDirectory: true)
    }
    static func load() throws -> MirrorConfig {
        let file = directory().appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(MirrorConfig.self, from: data) { return config }
        var config = MirrorConfig(token: Self.randomToken())
        try config.save()
        return config
    }
    func save() throws {
        let directory = Self.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let file = directory.appendingPathComponent("config.json")
        try? FileManager.default.removeItem(at: file)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) } }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
