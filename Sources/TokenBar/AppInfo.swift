import Foundation

enum AppInfo {
    static let name = "TokenBar"
    static let version = "1.3.0"
    static let build = "2"
    static let author = "Jash Jacob"

    static var versionLine: String { "Version \(version)" }
    static var buildLine: String { "Build \(build)" }
    static var creditLine: String { "Built by \(author)" }
}
