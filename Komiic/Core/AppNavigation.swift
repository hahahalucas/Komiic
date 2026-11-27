import SwiftUI

struct BookshelfRoute: Hashable {
    let id: UUID
}

struct ReaderLaunch: Identifiable {
    let id = UUID()
    let comic: Comic
    let chapter: Chapter
    var page = 0
    var chapterDirectory: [Chapter] = []
    var onDismiss: ((Bool) -> Void)? = nil
}

struct ReaderPosition: Codable {
    let mode: ComicContentMode
    let comic: Comic
    let chapter: Chapter
    let page: Int
}

private struct OpenAuthorKey: EnvironmentKey {
    static let defaultValue: (ComicAuthor) -> Void = { _ in }
}

private struct OpenComicDirectoryKey: EnvironmentKey {
    static let defaultValue: (Comic) -> Void = { _ in }
}

private struct OpenReaderKey: EnvironmentKey {
    static let defaultValue: (ReaderLaunch) -> Void = { _ in }
}

extension EnvironmentValues {
    var openComicDirectory: (Comic) -> Void {
        get { self[OpenComicDirectoryKey.self] }
        set { self[OpenComicDirectoryKey.self] = newValue }
    }
    var openAuthor: (ComicAuthor) -> Void {
        get { self[OpenAuthorKey.self] }
        set { self[OpenAuthorKey.self] = newValue }
    }
    var openReader: (ReaderLaunch) -> Void {
        get { self[OpenReaderKey.self] }
        set { self[OpenReaderKey.self] = newValue }
    }
}
