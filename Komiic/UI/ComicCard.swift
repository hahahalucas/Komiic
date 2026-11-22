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
    var progressLabel: String? = nil
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ComicCover(comic: comic)
                if let progressLabel {
                    Text(progressLabel).font(.system(size: 10, weight: .medium))
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
                Divider()
                HStack {
                    Text(comic.displayStatus).foregroundStyle(KomiicTheme.accent)
                    Spacer(minLength: 2)
                    Text(comic.updatedSummary).lineLimit(1)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(9)
        }
        .background(KomiicTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KomiicTheme.line, lineWidth: 0.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ComicGrid: View {
    let comics: [Comic]
    var onSelect: ((Comic) -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var settings: ReaderSettings
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 105,
                                             maximum: sizeClass == .regular ? 220 : 170), spacing: 12)], spacing: 18) {
            ForEach(comics.filter { !settings.shouldHide($0) }) { comic in
                Group {
                    if let onSelect {
                        Button { onSelect(comic) } label: { ComicCard(comic: comic) }
                    } else {
                        NavigationLink(value: comic) { ComicCard(comic: comic) }
                    }
                }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ComicContextMenu(comic: comic)
                    }
            }
        }
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
