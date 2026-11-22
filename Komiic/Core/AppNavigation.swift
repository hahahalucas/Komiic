import SwiftUI

private struct OpenAuthorKey: EnvironmentKey {
    static let defaultValue: (ComicAuthor) -> Void = { _ in }
}

extension EnvironmentValues {
    var openAuthor: (ComicAuthor) -> Void {
        get { self[OpenAuthorKey.self] }
        set { self[OpenAuthorKey.self] = newValue }
    }
}
