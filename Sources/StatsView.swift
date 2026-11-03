import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Твой год": what went into the library over a year, from Music Drop's own history.
struct StatsView: View {
    let store: ImportStore
    let tint: Color
    @State private var year: Int
    private let years: [Int]

    init(store: ImportStore, tint: Color) {
        self.store = store
        self.tint = tint
        let years = LibraryStats.years(store.entries)
        self.years = years
        _year = State(initialValue: years.first ?? Calendar.current.component(.year, from: Date()))
    }

    private var playlistName: String { "Music Drop · \(String(year))" }

    var body: some View {
        let stats = LibraryStats.make(store.entries, year: year)
        VStack(alignment: .leading, spacing: 12) {
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
                StatsCard(stats: stats, tint: tint)
                actions(stats)
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func actions(_ stats: LibraryStats) -> some View {
        HStack(spacing: 12) {
            if let build = store.playlistBuild {
                ProgressView(value: Double(build.done), total: Double(max(1, build.total))).frame(width: 60)
                Text("Плейлист: \(build.done) из \(build.total)").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button { store.buildPlaylist(playlistName, from: LibraryStats.imported(store.entries, year: year)) } label: {
                    Label("Плейлист года", systemImage: "music.note.list")
                }
                .help("Собрать в «Музыке» плейлист «\(playlistName)» из треков этого года")
            }
            Spacer()
            Menu {
                Button("Скопировать картинку") { copyCard(stats) }
                Button("Сохранить картинку…") { saveCard(stats) }
            } label: {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless).font(.system(size: 11))
    }

    /// The card as a picture for messages and stories, with Music Drop's name under it.
    @MainActor private func render(_ stats: LibraryStats) -> NSImage? {
        let card = VStack(alignment: .leading, spacing: 12) {
            Text("Твой \(String(stats.year)) в музыке").font(.system(size: 19, weight: .bold))
            StatsCard(stats: stats, tint: tint)
            Text("Music Drop").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return renderer.nsImage
    }

    @MainActor private func copyCard(_ stats: LibraryStats) {
        guard let image = render(stats) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        store.notice = "Картинка «Твой \(String(stats.year))» скопирована."
    }

    @MainActor private func saveCard(_ stats: LibraryStats) {
        guard let image = render(stats), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Music Drop \(String(stats.year)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url, options: .atomic) }
        catch { store.notice = "Не удалось сохранить картинку: " + error.localizedDescription }
    }
}

/// The numbers themselves, shared by the panel and the exported picture.
struct StatsCard: View {
    let stats: LibraryStats
    let tint: Color
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                tile(String(stats.tracks), LibraryStats.word(stats.tracks, "трек", "трека", "треков"))
                tile(LibraryStats.listening(stats.seconds), "музыки")
                tile(String(stats.longestStreak), LibraryStats.word(stats.longestStreak, "день", "дня", "дней") + " подряд")
            }
            months
            sources
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

    private var months: some View {
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

    private var sources: some View {
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
