import SwiftUI

/// "Твой год": what went into the library over a year, from Music Drop's own history.
struct StatsView: View {
    let entries: [ImportEntry]
    let tint: Color
    @State private var year: Int
    private let years: [Int]
    private static let letters = ["Я", "Ф", "М", "А", "М", "И", "И", "А", "С", "О", "Н", "Д"]
    private static let monthNames: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.standaloneMonthSymbols
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    init(entries: [ImportEntry], tint: Color) {
        self.entries = entries
        self.tint = tint
        let years = LibraryStats.years(entries)
        self.years = years
        _year = State(initialValue: years.first ?? Calendar.current.component(.year, from: Date()))
    }

    var body: some View {
        let stats = LibraryStats.make(entries, year: year)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Твой \(String(year))").font(.system(size: 17, weight: .bold))
                Spacer()
                if years.count > 1 {
                    Picker("Год", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                }
            }
            if stats.tracks == 0 {
                Text("В этом году через Music Drop ещё ничего не добавлено.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    tile(String(stats.tracks), LibraryStats.word(stats.tracks, "трек", "трека", "треков"))
                    tile(LibraryStats.listening(stats.seconds), "музыки")
                    tile(String(stats.longestStreak), LibraryStats.word(stats.longestStreak, "день", "дня", "дней") + " подряд")
                }
                months(stats)
                sources(stats)
                if !stats.artists.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Чаще всего").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(stats.artists.enumerated()), id: \.offset) { index, artist in
                            HStack {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
                                Text(artist.name).lineLimit(1)
                                Spacer()
                                Text(LibraryStats.plural(artist.count, "трек", "трека", "треков")).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
                if let day = stats.busiestDay, stats.busiestDayCount > 1 {
                    Label("Самый активный день — \(Self.dayFormatter.string(from: day)): "
                          + LibraryStats.plural(stats.busiestDayCount, "трек", "трека", "треков"), systemImage: "flame")
                        .font(.system(size: 11))
                }
                if let playlist = stats.playlists.first {
                    Label("Любимый плейлист — «\(playlist.name)»", systemImage: "music.note.list").font(.system(size: 11))
                }
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tile(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func months(_ stats: LibraryStats) -> some View {
        let peak = max(1, stats.months.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<12, id: \.self) { month in
                let count = stats.months[month]
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(count == 0 ? Color.secondary.opacity(0.15) : tint)
                        .frame(height: max(3, 54 * CGFloat(count) / CGFloat(peak)))
                    Text(Self.letters[month]).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(Self.monthNames[month].capitalized): \(count)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.monthNames[month].capitalized): \(LibraryStats.plural(count, "трек", "трека", "треков"))")
            }
        }
        .frame(height: 72, alignment: .bottom)
    }

    private func sources(_ stats: LibraryStats) -> some View {
        let parts: [(String, Int, Color)] = [("SoundCloud", stats.soundCloud, .orange), ("YouTube", stats.youTube, .red),
                                             ("Файлы", stats.files, .gray)].filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        RoundedRectangle(cornerRadius: 3).fill(part.2)
                            .frame(width: max(4, (geometry.size.width - CGFloat(parts.count - 1) * 2) * CGFloat(part.1) / CGFloat(max(1, stats.tracks))))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Text(parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
