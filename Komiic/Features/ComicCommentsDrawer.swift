import SwiftUI

struct ComicCommentsDrawer: View {
    let comicID: String
    let mode: ComicContentMode
    let onClose: () -> Void
    @EnvironmentObject private var content: AppContentStore
    @Environment(\.komiicTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visible = false
    @State private var closing = false

    private var motion: Animation { .easeInOut(duration: reduceMotion ? 0.15 : 0.26) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                if visible {
                    Color.black.opacity(0.42).ignoresSafeArea()
                        .onTapGesture(perform: close).accessibilityHidden(true)
                        .transition(.opacity)
                    ComicCommentsPanel(comicID: comicID, mode: mode, close: close)
                        .id(content.revision)
                        .frame(width: width(in: geometry.size.width), height: geometry.size.height)
                        .background {
                            UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22)
                                .fill(theme.canvas).ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
                        }
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .presentationBackground(.clear)
        .onAppear { withAnimation(motion) { visible = true } }
        .accessibilityAction(.escape) { close() }
    }

    private func width(in available: CGFloat) -> CGFloat {
        let preferred: CGFloat = dynamicTypeSize.isAccessibilitySize ? 540 : 460
        let fraction: CGFloat = dynamicTypeSize.isAccessibilitySize ? 0.9 : 0.76
        return max(0, min(preferred, available - 20, max(270, available * fraction)))
    }

    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(motion, completionCriteria: .removed) {
            visible = false
        } completion: {
            onClose()
        }
    }
}

private struct ComicCommentsPanel: View {
    let comicID: String
    let mode: ComicContentMode
    let close: () -> Void
    @Environment(\.komiicTheme) private var theme
    @StateObject private var model: CommentListModel
    @State private var votes: [String: Bool]?
    @State private var votesFailed = false
    @State private var votesInFlight: Set<String> = []
    @State private var replyTo: ComicComment?
    @State private var composing = false
    @State private var draft = ""
    @State private var sending = false
    @State private var status: String?
    @FocusState private var editorFocused: Bool

    init(comicID: String, mode: ComicContentMode, close: @escaping () -> Void) {
        self.comicID = comicID
        self.mode = mode
        self.close = close
        _model = StateObject(wrappedValue: CommentListModel(mode: mode, source: .comic(comicID)))
    }

    private var signedIn: Bool { SessionCookieStore.shared.scope(for: mode) != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("评论区").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("关闭评论区")
            }
            .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 3)
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if votesFailed && signedIn {
                        Button("重新读取点赞状态") { Task { await loadVotes() } }
                            .font(.footnote).buttonStyle(.bordered)
                    }
                    ForEach(model.comments) { comment in commentCard(comment) }
                    if model.loaded && model.comments.isEmpty && !model.hasMore && model.error == nil {
                        ContentUnavailableView("暂无评论", systemImage: "bubble.left.and.bubble.right")
                            .frame(maxWidth: .infinity, minHeight: 210)
                    }
                    CommentListFooter(model: model, disablesPagination: sending)
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            Divider()
            footer
        }
        .task {
            async let comments: Void = model.load()
            await loadVotes()
            await comments
        }
    }

    private func commentCard(_ comment: ComicComment) -> some View {
        CommentCard(comment: comment, selection: votes?[comment.id],
                    voteDisabled: votes == nil || votesInFlight.contains(comment.id),
                    onReply: signedIn ? { beginReply(to: comment) } : nil,
                    onVote: signedIn ? { up in Task { await vote(comment, up: up) } } : nil)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if !signedIn {
                Text("在账号页登录后可以留言").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else if composing {
                composer
            } else {
                Button { composing = true; editorFocused = true } label: {
                    Label("留言", systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .komiicActionStyle()
            }
        }
        .padding(12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let replyTo {
                    Label("回复 \(replyTo.authorName)", systemImage: "arrowshape.turn.up.left")
                        .lineLimit(1).foregroundStyle(theme.accent)
                }
                Spacer(minLength: 4)
                Button("取消") {
                    editorFocused = false
                    composing = false
                    replyTo = nil
                }
                .disabled(sending)
            }
            .font(.footnote)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("写下留言", text: $draft, axis: .vertical)
                    .font(.subheadline).lineLimit(2...4).focused($editorFocused)
                    .padding(9).komiicCard().disabled(sending)
                Button { Task { await sendComment() } } label: {
                    Group {
                        if sending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "paperplane.fill") }
                    }
                    .frame(width: 38, height: 38)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || model.loading)
                .accessibilityLabel("发送留言")
            }
        }
    }

    private func beginReply(to comment: ComicComment) {
        guard !sending else { return }
        replyTo = comment
        composing = true
        editorFocused = true
    }

    private func loadVotes() async {
        guard let scope = SessionCookieStore.shared.scope(for: mode) else { return }
        votesFailed = false
        do {
            let fetched = try await model.api.commentVotes(comicID: comicID)
            if model.scopeIsCurrent(scope) { votes = fetched }
        } catch {
            if model.scopeIsCurrent(scope) { votesFailed = true }
        }
    }

    private func sendComment() async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending, !model.loading,
              let scope = SessionCookieStore.shared.scope(for: mode) else { return }
        sending = true
        status = nil
        defer { sending = false }
        do {
            let comment = try await model.api.postComment(comicID: comicID, message: message, replyingTo: replyTo?.id)
            guard model.scopeIsCurrent(scope) else { return }
            if comment.reviewing == true {
                status = "留言已提交，等待官网审核。"
            } else {
                model.insert(comment)
                status = "留言已发布。"
            }
            draft = ""
            replyTo = nil
            editorFocused = false
            composing = false
        } catch {
            if model.scopeIsCurrent(scope) { status = error.localizedDescription }
        }
    }

    private func vote(_ comment: ComicComment, up: Bool) async {
        guard let votes, let scope = SessionCookieStore.shared.scope(for: mode),
              votesInFlight.insert(comment.id).inserted else { return }
        let previous = votes[comment.id]
        let next: Bool? = previous == up ? nil : up
        defer { votesInFlight.remove(comment.id) }
        status = nil
        do {
            try await model.api.voteOnComment(id: comment.id, up: up)
            guard model.scopeIsCurrent(scope) else { return }
            self.votes?[comment.id] = next
            model.applyVote(id: comment.id, from: previous, to: next)
        } catch {
            if model.scopeIsCurrent(scope) { status = error.localizedDescription }
        }
    }
}
