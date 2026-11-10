import Foundation

/// A soft line when OpenCode or Command Code is inside the last day before it renews.
/// The leftover line already covers a month that still has allowance.
enum RenewalReminder {
    static let horizon: TimeInterval = 24 * 3600
    /// Chip id to the name the sentence says.
    private static let names = [
        "opencodeGo.tertiary_window": "OpenCode",
        "commandCode.tertiary_window": "Command Code",
    ]

    static func qualifies(id: String, remaining: TimeInterval) -> Bool {
        names[id] != nil && remaining > LeftoverBanner.floor && remaining <= horizon
    }

    static func sentence(id: String, remaining: TimeInterval) -> String? {
        guard let name = names[id] else { return nil }
        return "\(name) starts over in \(LeftoverBanner.time(remaining))."
    }
}
