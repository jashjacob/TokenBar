import Foundation

enum ChipPreferences {
    static let todayID = "today"
    static let todayTokensID = "today.tokens"
    static let todayCostID = "today.cost"
    static let todayMetricIDs = [todayTokensID, todayCostID]
    private static let hiddenKey = "touchBarHiddenIDs"
    private static let migratedTodayKey = "migratedTodaySplit"

    /// Old combined Today chip → two independent tokens / cost chips.
    static func migrateTodaySplit() {
        guard !UserDefaults.standard.bool(forKey: migratedTodayKey) else { return }
        var hidden = hiddenIDs
        if hidden.contains(todayID) {
            hidden.remove(todayID)
            hidden.insert(todayTokensID)
            hidden.insert(todayCostID)
            hiddenIDs = hidden
        }
        UserDefaults.standard.set(true, forKey: migratedTodayKey)
    }

    static var hiddenIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey) }
    }

    static func isVisible(_ id: String) -> Bool {
        !hiddenIDs.contains(id)
    }

    static func setVisible(_ id: String, _ visible: Bool) {
        var hidden = hiddenIDs
        if visible {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        hiddenIDs = hidden
    }

    static func toggle(_ id: String) {
        setVisible(id, !isVisible(id))
    }

    static func setAllVisible(_ ids: [String], _ visible: Bool) {
        if visible {
            hiddenIDs = hiddenIDs.subtracting(ids)
        } else {
            hiddenIDs = hiddenIDs.union(ids)
        }
    }
}
