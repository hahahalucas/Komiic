import Foundation

struct ReaderSpreadLayout {
    let pageCount: Int
    let doublePage: Bool
    let direction: ReadingDirection

    var step: Int { doublePage ? 2 : 1 }
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

    func next(from page: Int) -> Int { min(start(for: page) + step, starts.last ?? 0) }
    func previous(from page: Int) -> Int { max(0, start(for: page) - step) }
}
