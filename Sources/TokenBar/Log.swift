import Foundation

enum Log {
    private static let maxBytes = 256_000

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("TokenBar.log")
    }()

    static func line(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let safe = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let row = "\(stamp) \(safe)\n"
        FileHandle.standardError.write(Data(row.utf8))
        guard let data = row.data(using: .utf8) else { return }
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue >= maxBytes
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
