import Foundation

struct ReaderSpreadLayout: Equatable {
    let pageCount: Int
    let doublePage: Bool
    let direction: ReadingDirection

    var step: Int { doublePage ? 2 : 1 }
    var count: Int { pageCount > 0 ? (pageCount - 1) / step + 1 : 0 }
    var starts: [Int] { Array(stride(from: 0, to: max(0, pageCount), by: step)) }

    func start(for page: Int) -> Int {
        let clamped = min(max(0, page), max(0, pageCount - 1))
        return clamped / step * step
    }

    /// Slots are physical left/right positions, independent of interface language.
    func slots(for page: Int) -> [Int?] {
        let first = start(for: page)
        guard pageCount > 0 else { return [] }
        guard doublePage else { return [first] }
        let second: Int? = first + 1 < pageCount ? first + 1 : nil
        return direction == .right ? [first, second] : [second, first]
    }

    func horizontalIndex(for page: Int) -> Int {
        let index = start(for: page) / step
        return direction == .right ? index : max(0, count - 1) - index
    }

    func page(atHorizontalIndex index: Int) -> Int {
        let readingIndex = direction == .right ? index : count - 1 - index
        return start(for: readingIndex * step)
    }

    func isForwardSwipe(_ translation: CGPoint) -> Bool {
        let forward = direction == .right ? -translation.x : translation.x
        return forward > 65 && forward > abs(translation.y) * 1.5
    }

    func next(from page: Int) -> Int { start(for: start(for: page) + step) }
    func previous(from page: Int) -> Int { max(0, start(for: page) - step) }
}
