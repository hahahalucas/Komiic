import SwiftUI

struct BookshelfRoute: Hashable {
    let id: UUID
}

private struct OpenAuthorKey: EnvironmentKey {
    static let defaultValue: (ComicAuthor) -> Void = { _ in }
}

private struct OpenComicDirectoryKey: EnvironmentKey {
    static let defaultValue: (Comic) -> Void = { _ in }
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
}
