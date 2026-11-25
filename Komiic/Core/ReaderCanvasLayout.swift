import Foundation

enum ReaderCanvasMode: Equatable {
    case chapter
    case spread([Int?])

    var isChapter: Bool { if case .chapter = self { return true }; return false }
}

/// All page frames are expressed at 1x; one native canvas scales them together.
struct ReaderCanvasLayout: Equatable {
    struct Item: Identifiable, Equatable {
        let id: Int
        let frame: CGRect
    }
    let items: [Item]
    let size: CGSize
    let footerFrame: CGRect?

    init(pages: [ComicPage], viewport: CGSize, mode: ReaderCanvasMode, spacing: CGFloat = 8) {
        let width = max(1, viewport.width), height = max(1, viewport.height)
        var rows: [Item] = []
        func ratio(_ index: Int) -> CGFloat {
            let page = pages[index]
            return page.width > 0 && page.height > 0 ? CGFloat(page.width) / CGFloat(page.height) : 0.7
        }
        switch mode {
        case .chapter:
            let pageWidth = min(width, 1_000)
            var y: CGFloat = 0
            for index in pages.indices {
                let pageHeight = pageWidth / ratio(index)
                rows.append(Item(id: index, frame: CGRect(x: (width - pageWidth) / 2, y: y, width: pageWidth, height: pageHeight)))
                y += pageHeight + max(0, spacing)
            }
            if !pages.isEmpty { y -= max(0, spacing) }
            footerFrame = CGRect(x: 0, y: y, width: width, height: 72)
            size = CGSize(width: width, height: max(height, y + 72))
        case .spread(let slots):
            let slotWidth = width / CGFloat(max(1, slots.count))
            for (slot, index) in slots.enumerated() {
                guard let index, pages.indices.contains(index) else { continue }
                let pageWidth = min(slotWidth, height * ratio(index))
                let pageHeight = pageWidth / ratio(index)
                let inset = slots.count == 1 ? (slotWidth - pageWidth) / 2 : (slot == 0 ? slotWidth - pageWidth : 0)
                rows.append(Item(id: index, frame: CGRect(x: CGFloat(slot) * slotWidth + inset,
                    y: (height - pageHeight) / 2, width: pageWidth, height: pageHeight)))
            }
            footerFrame = nil
            size = CGSize(width: width, height: height)
        }
        items = rows
    }

    func visiblePages(in rect: CGRect) -> Set<Int> {
        let preload = rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height)
        return Set(items.filter { $0.frame.intersects(preload) }.map(\.id))
    }

    func page(at y: CGFloat) -> Int {
        guard !items.isEmpty else { return 0 }
        var low = 0, high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle].frame.minY <= y + 1 { low = middle + 1 }
            else { high = middle }
        }
        return items[max(0, low - 1)].id
    }
}

enum ReaderChromePlacement {
    static func topPadding(safeAreaTop: CGFloat) -> CGFloat { max(0, safeAreaTop) + 8 }
}
