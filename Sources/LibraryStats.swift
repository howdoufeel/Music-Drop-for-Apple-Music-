import Foundation

/// A year of imports at a glance, counted from the history; only tracks that reached Music count.
struct LibraryStats: Equatable {
    struct Count: Equatable {
        let name: String
        let count: Int
    }

    let year: Int
    let tracks: Int
    let seconds: Double
    let soundCloud: Int
    let youTube: Int
    let files: Int
    /// Tracks per month, January first.
    let months: [Int]
    let artists: [Count]
    let playlists: [Count]
    let busiestDay: Date?
    let busiestDayCount: Int
    let longestStreak: Int

    /// Years with at least one import, newest first.
    static func years(_ entries: [ImportEntry], calendar: Calendar = .current) -> [Int] {
        Set(entries.filter { $0.stage == .imported }.map { calendar.component(.year, from: $0.date) }).sorted(by: >)
    }

    static func make(_ entries: [ImportEntry], year: Int, calendar: Calendar = .current) -> LibraryStats {
        let imported = entries.filter { $0.stage == .imported && calendar.component(.year, from: $0.date) == year }
        var months = Array(repeating: 0, count: 12)
        var days: [Date: Int] = [:]
        for entry in imported {
            months[calendar.component(.month, from: entry.date) - 1] += 1
            days[calendar.startOfDay(for: entry.date), default: 0] += 1
        }
        let busiest = days.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
        return LibraryStats(
            year: year,
            tracks: imported.count,
            seconds: imported.compactMap(\.duration).filter { $0.isFinite && $0 > 0 }.reduce(0, +),
            soundCloud: imported.filter { $0.soundCloudID != nil }.count,
            youTube: imported.filter { $0.youtubeID != nil }.count,
            files: imported.filter { $0.soundCloudID == nil && $0.youtubeID == nil }.count,
            months: months,
            artists: top(imported.compactMap { $0.artist?.nonEmpty }, limit: 5),
            playlists: top(imported.compactMap { $0.playlist?.nonEmpty }, limit: 3),
            busiestDay: busiest?.key,
            busiestDayCount: busiest?.value ?? 0,
            longestStreak: streak(Array(days.keys), calendar: calendar))
    }

    /// Most frequent names, ignoring case; ties go to the name seen first.
    private static func top(_ names: [String], limit: Int) -> [Count] {
        var counts: [String: (name: String, count: Int, first: Int)] = [:]
        for (index, name) in names.enumerated() {
            let key = name.lowercased()
            if let current = counts[key] { counts[key] = (current.name, current.count + 1, current.first) }
            else { counts[key] = (name, 1, index) }
        }
        return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .prefix(limit).map { Count(name: $0.name, count: $0.count) }
    }

    private static func streak(_ days: [Date], calendar: Calendar) -> Int {
        var best = 0, current = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous), calendar.isDate(next, inSameDayAs: day) {
                current += 1
            } else {
                current = 1
            }
            best = max(best, current)
            previous = day
        }
        return best
    }

    /// "1 трек", "3 дня": Russian picks the word by the last digits.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(count) " + word(count, one, few, many)
    }

    static func word(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = count % 100, ones = count % 10
        return (11...14).contains(tens) ? many : ones == 1 ? one : (2...4).contains(ones) ? few : many
    }

    /// Minutes under an hour, then hours with one decimal.
    static func listening(_ seconds: Double) -> String {
        guard seconds >= 3_600 else { return "\(Int(seconds / 60)) мин" }
        return String(format: "%.1f ч", locale: Locale(identifier: "ru_RU"), seconds / 3_600)
    }
}
