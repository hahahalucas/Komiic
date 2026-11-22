import Foundation

enum ReaderChapterNavigation {
    static func ordered(_ chapters: [Chapter], current: Chapter) -> [Chapter] {
        chapters.filter { $0.type == current.type }.sorted {
            let order = $0.serial.compare($1.serial, options: .numeric)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func nearby(_ chapters: [Chapter], current: Chapter) -> [Chapter] {
        let ordered = ordered(chapters, current: current)
        guard let index = ordered.firstIndex(where: { $0.id == current.id }) else { return [] }
        let start = max(0, min(index - 2, ordered.count - 5))
        return Array(ordered.dropFirst(start).prefix(5))
    }

    static func next(_ chapters: [Chapter], current: Chapter) -> Chapter? {
        let ordered = ordered(chapters, current: current)
        guard let index = ordered.firstIndex(where: { $0.id == current.id }), index + 1 < ordered.count else { return nil }
        return ordered[index + 1]
    }
}
