import SwiftUI

@MainActor
final class CommentListModel: ObservableObject {
    enum Source {
        case comic(String)
        case account
    }

    let api: KomiicAPI
    private let source: Source
    @Published private(set) var comments: [ComicComment] = []
    @Published private(set) var works: [String: Comic] = [:]
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    private var nextOffset: Int? = 0
    private var retryResets = false

    var hasMore: Bool { nextOffset != nil }

    init(mode: ComicContentMode, source: Source) {
        api = KomiicAPI(mode: mode)
        self.source = source
    }

    func load(reset: Bool = false) async {
        let reset = reset || retryResets
        guard !loading, let offset = reset ? 0 : nextOffset else { return }
        let scope = SessionCookieStore.shared.scope(for: api.mode)
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page: CommentPage
            switch source {
            case .comic(let id): page = try await api.comicComments(comicID: id, offset: offset)
            case .account: page = try await api.myComments(offset: offset)
            }
            guard scopeIsCurrent(scope) else { return }
            if reset { comments = []; works = [:] }
            var known = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { known.insert($0.id).inserted })
            nextOffset = page.nextOffset
            retryResets = false
            loaded = true

            if case .account = source {
                let ids = Set(page.comments.map(\.comicId)).subtracting(works.keys)
                if !ids.isEmpty, let matches = try? await api.comics(ids: ids.sorted()), scopeIsCurrent(scope) {
                    for comic in matches { works[comic.id] = comic }
                }
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if scopeIsCurrent(scope) {
                self.error = error.localizedDescription
                retryResets = reset
            }
        }
    }

    func insert(_ comment: ComicComment) {
        guard !comments.contains(where: { $0.id == comment.id }) else { return }
        comments.insert(comment, at: 0)
        if let nextOffset { self.nextOffset = nextOffset + 1 }
    }

    func applyVote(id: String, from previous: Bool?, to next: Bool?) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[index].applyVote(from: previous, to: next)
    }

    func scopeIsCurrent(_ scope: String?) -> Bool {
        !Task.isCancelled && SessionCookieStore.shared.scope(for: api.mode) == scope
    }
}

struct MyCommentsView: View {
    @StateObject private var model: CommentListModel

    init(mode: ComicContentMode) {
        _model = StateObject(wrappedValue: CommentListModel(mode: mode, source: .account))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.comments) { comment in
                    VStack(alignment: .leading, spacing: 9) {
                        let comic = model.works[comment.comicId] ?? Comic(id: comment.comicId, title: "漫画 #\(comment.comicId)")
                        NavigationLink(value: comic) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(comic.title).font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(KomiicTheme.accent)
                            .padding(.horizontal, 4).padding(.vertical, 5)
                        }
                        CommentCard(comment: comment)
                    }
                }
                if model.loaded && model.comments.isEmpty && !model.hasMore && model.error == nil {
                    ContentUnavailableView("还没有留言", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                CommentListFooter(model: model)
            }
            .padding(18).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(KomiicTheme.canvas)
        .navigationTitle("我的留言").navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.always, axes: .vertical)
        .task { if !model.loaded { await model.load() } }
        .refreshable { await model.load(reset: true) }
    }
}

struct CommentListFooter: View {
    @ObservedObject var model: CommentListModel
    var disablesPagination = false

    var body: some View {
        VStack(spacing: 8) {
            if model.loading {
                ProgressView("正在读取留言…").controlSize(.small)
            } else if let error = model.error {
                Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重试") { Task { await model.load() } }.buttonStyle(.bordered)
                    .disabled(disablesPagination)
            } else if model.loaded && model.hasMore {
                Button("加载更多") { Task { await model.load() } }.buttonStyle(.bordered)
                    .disabled(disablesPagination)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct CommentCard: View {
    let comment: ComicComment
    var selection: Bool? = nil
    var voteDisabled = false
    var onReply: (() -> Void)? = nil
    var onVote: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                avatar(comment.account, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(comment.authorName).font(.subheadline.bold())
                    if let date = formattedDate {
                        Text(date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if comment.isDeleted {
                Text("留言已删除").font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let quote = comment.replyTo { quotedComment(quote) }
                if let message = comment.message { Text(message).font(.subheadline).textSelection(.enabled) }
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13).komiicCard()
    }

    private var formattedDate: String? {
        guard let source = comment.dateCreated, !source.isEmpty else { return nil }
        let date = (try? Date.ISO8601FormatStyle().parse(source))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(source))
        return date?.formatted(.relative(presentation: .named)) ?? String(source.prefix(10))
    }

    private func avatar(_ author: CommentAuthor?, size: CGFloat) -> some View {
        KomiicAvatar(name: author?.name ?? "", profileText: author?.profileText, url: author?.profileImageUrl, size: size)
    }

    private func quotedComment(_ quote: CommentQuote) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if quote.deleted == true {
                Label("原留言已删除", systemImage: "arrowshape.turn.up.left")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                    avatar(quote.account, size: 24)
                    Text(quote.account?.name ?? "Komiic 用户").fontWeight(.semibold)
                }
                .font(.caption)
                if let message = quote.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
        .background(KomiicTheme.softBlue, in: RoundedRectangle(cornerRadius: 10))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let onReply {
                Button(action: onReply) {
                    Image(systemName: "arrowshape.turn.up.left").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("回复 \(comment.authorName)")
            }
            vote(up: true, count: comment.upCount ?? 0)
            vote(up: false, count: comment.downCount ?? 0)
        }
        .font(.footnote)
    }

    @ViewBuilder private func vote(up: Bool, count: Int) -> some View {
        let title = up ? "赞" : "踩"
        let selected = selection == up
        let symbol = up ? "hand.thumbsup" : "hand.thumbsdown"
        if let onVote {
            Button { onVote(up) } label: {
                voteLabel(symbol: symbol, count: count, selected: selected).frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain).disabled(voteDisabled)
            .accessibilityLabel(selected ? "取消\(title)" : title)
            .accessibilityValue(String(count))
        } else if count > 0 {
            voteLabel(symbol: symbol, count: count, selected: false).accessibilityLabel("\(title) \(count)")
        }
    }

    private func voteLabel(symbol: String, count: Int, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: selected ? "\(symbol).fill" : symbol)
            if count > 0 { Text(count.formatted()).monospacedDigit() }
        }
        .foregroundStyle(selected ? KomiicTheme.accent : Color.secondary)
    }
}
