import Foundation

/// Month-to-date spend vs a monthly budget, with a simple end-of-month projection.
struct BudgetStatus: Equatable {
    let monthToDate: Double
    let projected: Double   // estimated month-end total at the current daily pace
    let budget: Double

    var fraction: Double { budget > 0 ? min(1, monthToDate / budget) : 0 }
    var projectedOver: Bool { budget > 0 && projected > budget }
}

enum Budget {
    /// `history` is per-day cost (date "yyyy-MM-dd"); only the current month is counted.
    static func status(history: [DailyCost], now: Date, budget: Double,
                       calendar: Calendar = .current) -> BudgetStatus {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM"
        let prefix = f.string(from: now)

        let monthToDate = history.filter { $0.date.hasPrefix(prefix) }.reduce(0.0) { $0 + $1.cost }
        let day = calendar.component(.day, from: now)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let projected = day > 0 ? monthToDate / Double(day) * Double(daysInMonth) : monthToDate

        return BudgetStatus(monthToDate: monthToDate, projected: projected, budget: budget)
    }
}
