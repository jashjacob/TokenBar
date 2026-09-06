import Foundation

struct TodayUsage: Equatable {
    var tokens: Double
    var costUSD: Double

    var tokenText: String { TokenFormat.compact(tokens) }

    var costText: String {
        String(format: "$%.2f", costUSD)
    }

    var tokenMenuTitle: String { "Today  \(tokenText)" }
    var costMenuTitle: String { "Cost  \(costText)" }
    var menuTitle: String { "\(tokenMenuTitle)  \(costText)" }
}

enum TokenFormat {
    static func compact(_ n: Double) -> String {
        let abs = Swift.abs(n)
        let divisor: Double
        let suffix: String
        if abs >= 1_000_000_000 {
            divisor = 1_000_000_000
            suffix = "B"
        } else if abs >= 1_000_000 {
            divisor = 1_000_000
            suffix = "M"
        } else if abs >= 1_000 {
            divisor = 1_000
            suffix = "K"
        } else {
            return String(Int(n.rounded()))
        }
        return String(format: "%.1f", n / divisor) + suffix
    }
}
