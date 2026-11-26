import SwiftUI

extension Comic {
    var displayStatus: String {
        if status.uppercased() == "SHORT" { return "短篇" }
        return ["END", "COMPLETED", "FINISHED", "完结", "完結"].contains(status.uppercased()) ? "完结" : "连载"
    }
    var chapterSummary: String {
        let parts = [lastChapterUpdate.flatMap { $0.isEmpty ? nil : "\($0) 话" },
                     lastBookUpdate.flatMap { $0.isEmpty ? nil : "\($0) 卷" }].compactMap { $0 }
        return parts.isEmpty ? "查看章节" : parts.joined(separator: " · ")
    }
    var updatedSummary: String {
        guard let dateUpdated else { return "最近更新" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: dateUpdated) ?? ISO8601DateFormatter().date(from: dateUpdated)
        guard let date else { return String(dateUpdated.prefix(10)) }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

func compactCount(_ count: Int) -> String {
    if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000) }
    if count >= 1_000 { return String(format: "%.1f千", Double(count) / 1_000) }
    return String(count)
}

struct ComicCard: View {
    let comic: Comic
    var readingProgress: ReadingProgress? = nil
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.komiicTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ComicCover(comic: comic)
                if let readingProgress {
                    Text("第 \(readingProgress.page + 1) 页").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule()).padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(comic.title).font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).frame(height: 35, alignment: .topLeading)
                HStack(spacing: 3) {
                    Image(systemName: "eye").font(.system(size: 10))
                    Text(compactCount(comic.views))
                    Spacer(minLength: 0)
                    Image(systemName: library.isFavorite(comic) ? "heart.fill" : "heart")
                        .foregroundStyle(library.isFavorite(comic) ? Color.red : Color.secondary)
                    Text(compactCount(comic.favoriteCount))
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                if readingProgress != nil {
                    Text(comic.sexyLevel.map { $0 == 0 ? "色情程度 · 无" : "色情程度 · \($0)/5" } ?? "暂无分级")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                Divider()
                HStack {
                    Text(comic.displayStatus).foregroundStyle(theme.accent)
                    Spacer(minLength: 2)
                    Text(comic.updatedSummary).lineLimit(1)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(9)
        }
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            if let readingProgress, readingProgress.totalPages > 0 {
                ProgressView(value: readingProgress.fraction).tint(theme.accent)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KomiicTheme.line, lineWidth: 0.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

enum ComicGridColumns {
    static let spacing: CGFloat = 12

    static func count(for size: CGSize, isPad: Bool) -> Int {
        let landscape = size.width > size.height
        guard isPad else { return landscape ? 5 : 3 }
        let preferred = landscape ? 7 : 5
        let fitting = Int((size.width - 36 + spacing) / (88 + spacing))
        return max(1, min(preferred, fitting))
    }
}

private struct ComicGridColumnsKey: EnvironmentKey {
    static let defaultValue = 3
}

extension EnvironmentValues {
    var comicGridColumns: Int {
        get { self[ComicGridColumnsKey.self] }
        set { self[ComicGridColumnsKey.self] = newValue }
    }
}

struct ComicGridLayout<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.comicGridColumns) private var columnCount

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: ComicGridColumns.spacing), count: columnCount)
        LazyVGrid(columns: columns, spacing: 18, content: content)
    }
}

struct ComicGrid: View {
    let comics: [Comic]
    var onSelect: ((Comic) -> Void)? = nil
    @EnvironmentObject private var settings: ReaderSettings
    var body: some View {
        ComicGridLayout {
            ForEach(comics.filter { !settings.shouldHide($0) }) { comic in
                ComicActivation(comic: comic, action: onSelect.map { select in { select(comic) } }) {
                    ComicCard(comic: comic)
                }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ComicContextMenu(comic: comic)
                    }
            }
        }
    }
}

/// A warning consumes the first activation; the second uses the normal destination.
struct ComicActivation<Content: View>: View {
    let comic: Comic
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        Group {
            if settings.shouldBlur(comic) {
                Button { settings.revealWarningCover(comic) } label: { content() }
                    .accessibilityHint("轻点显示封面，再次轻点打开漫画")
            } else if let action {
                Button(action: action, label: content)
            } else {
                NavigationLink(value: comic, label: content)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ComicCover: View {
    let comic: Comic
    var aspectRatio: CGFloat = 0.72
    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        RemoteImage(url: settings.shouldHide(comic) ? nil : comic.imageUrl, aspectRatio: aspectRatio)
            .blur(radius: settings.shouldBlur(comic) ? 18 : 0, opaque: true)
            .overlay {
                if settings.shouldBlur(comic) || settings.shouldHide(comic) {
                    VStack(spacing: 7) {
                        Image(systemName: "eye.slash.fill")
                        Text("内容警告").font(.caption2)
                    }
                    .foregroundStyle(.primary).padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .clipped()
    }
}

struct ComicContextMenu: View {
    let comic: Comic
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        RemoveRecentReadingButton(comicID: comic.id)
        Button { library.toggleFavorite(comic) } label: {
            Label(library.isFavorite(comic) ? "取消喜爱" : "加入喜爱", systemImage: "heart")
        }
        if !library.shelves.isEmpty {
            Menu("加入书柜") {
                ForEach(library.shelves) { shelf in
                    Button(shelf.name) { library.addToShelf(comic, shelfID: shelf.id) }
                }
            }
        }
        Button(role: .destructive) { library.toggleBlocked(comic) } label: {
            Label("屏蔽这部漫画", systemImage: "eye.slash")
        }
    }
}

struct RemoveRecentReadingButton: View {
    let comicID: String
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if library.isInRecentReading(comicID: comicID) {
            Button("从最近阅读里移除", systemImage: "minus.circle", role: .destructive) {
                library.removeFromRecentReading(comicID: comicID)
            }
        }
    }
}
