import Foundation

enum ChapterDirectoryItem: Hashable, Identifiable {
    case chapter(Chapter)
    case collapsed([Chapter])

    var id: String {
        switch self {
        case .chapter(let chapter): return "chapter:\(chapter.id)"
        case .collapsed(let chapters): return "collapsed:\(chapters.first?.id ?? ""):\(chapters.last?.id ?? "")"
        }
    }
}

/// Calculates one volume/episode group's directory without inferring read status from serials.
enum ChapterDirectory {
    static func items(chapters: [Chapter], readChapterIDs: Set<String>, lastReadChapterID: String?,
                      expanded: Bool = false, ascending: Bool = true) -> [ChapterDirectoryItem] {
        let ordered = chapters.enumerated().sorted {
            let comparison = $0.element.serial.compare($1.element.serial, options: .numeric)
            return comparison == .orderedSame ? $0.offset < $1.offset : comparison == .orderedAscending
        }.map(\.element)

        if expanded {
            let result = ordered.map { ChapterDirectoryItem.chapter($0) }
            return ascending ? result : Array(result.reversed())
        }

        var visibleReadIDs: Set<String> = []
        var firstVisibleIndex = 0
        if let anchor = ordered.firstIndex(where: { $0.id == lastReadChapterID && readChapterIDs.contains($0.id) }) {
            firstVisibleIndex = anchor
            visibleReadIDs.insert(ordered[anchor].id)
            if anchor > 0 && readChapterIDs.contains(ordered[anchor - 1].id) {
                firstVisibleIndex -= 1
                visibleReadIDs.insert(ordered[anchor - 1].id)
            }
        }

        // The earlier prefix can contain skipped chapters; expanding it preserves their unread state.
        var hidden = Array(ordered.prefix(firstVisibleIndex))
        var result: [ChapterDirectoryItem] = []
        for chapter in ordered.dropFirst(firstVisibleIndex) {
            if readChapterIDs.contains(chapter.id) && !visibleReadIDs.contains(chapter.id) {
                hidden.append(chapter)
            } else {
                if !hidden.isEmpty {
                    result.append(.collapsed(hidden))
                    hidden = []
                }
                result.append(.chapter(chapter))
            }
        }
        if !hidden.isEmpty { result.append(.collapsed(hidden)) }
        return ascending ? result : Array(result.reversed())
    }
}
