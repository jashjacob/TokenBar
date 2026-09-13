import Foundation

enum AppInfo {
    static let name = "TokenBar"
    static let version = "1.2.0"
    static let build = "1"
    static let author = "Jash Jacob"

    static var versionLine: String { "Version \(version)" }
    static var buildLine: String { "Build \(build)" }
    static var creditLine: String { "Built by \(author)" }
}
