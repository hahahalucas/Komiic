import SwiftUI

struct AuthorView: View {
    let author: ComicAuthor
    @EnvironmentObject private var library: LibraryStore
    @State private var comics: [Comic] = []
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeading(title: author.name, subtitle: "作者作品")
                if loading {
                    ProgressView("正在加载作品…").frame(maxWidth: .infinity).padding(30)
                } else if let error {
                    EmptyState(symbol: "wifi.exclamationmark", title: "暂时无法加载", message: error,
                               actionTitle: "重试", action: { retry += 1 })
                } else if comics.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "暂无作品", message: "未找到这位作者的漫画。")
                } else {
                    ComicGrid(comics: comics.filter { !library.isBlocked($0) })
                }
            }.padding(18).frame(maxWidth: 1_200).frame(maxWidth: .infinity)
        }
        .background(KomiicTheme.canvas)
        .navigationTitle(author.name).navigationBarTitleDisplayMode(.inline)
        .task(id: retry) { await load() }
        .refreshable { await load() }
        .scrollBounceBehavior(.always)
    }

    @MainActor private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let api = KomiicAPI()
            var id = author.id
            if id.isEmpty {
                let matches = try await api.searchAuthors(keyword: author.name)
                guard let match = matches.first(where: { $0.name == author.name }) else {
                    comics = []
                    return
                }
                id = match.id
            }
            let result = try await api.comics(authorID: id)
            try Task.checkCancellation()
            comics = result
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch { self.error = error.localizedDescription }
    }
}
