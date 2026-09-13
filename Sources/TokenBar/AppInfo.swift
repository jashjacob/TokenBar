import Foundation

enum AppInfo {
    static let name = "TokenBar"
    static let version = "1.1.0"
    static let build = "14"
    static let author = "Jash Jacob"

    static var versionLine: String { "Version \(version)" }
    static var buildLine: String { "Build \(build)" }
    static var creditLine: String { "Built by \(author)" }
}
