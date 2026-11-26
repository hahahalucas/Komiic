import Foundation

struct ComicComment: Decodable, Identifiable, Sendable {
    let id: String
    let comicId: String
    let message: String?
    let deleted: Bool?
    let dateCreated: String?
    let reviewing: Bool?
    var account: CommentAuthor?
    var replyTo: CommentQuote?
    var upCount: Int?
    var downCount: Int?

    var isDeleted: Bool { deleted == true }
    var authorName: String { account?.name ?? "Komiic 用户" }

    mutating func applyVote(from previous: Bool?, to next: Bool?) {
        upCount = max(0, (upCount ?? 0) - (previous == true ? 1 : 0) + (next == true ? 1 : 0))
        downCount = max(0, (downCount ?? 0) - (previous == false ? 1 : 0) + (next == false ? 1 : 0))
    }
}

struct CommentQuote: Decodable, Sendable {
    let message: String?
    let deleted: Bool?
    var account: CommentAuthor?
}

struct CommentAuthor: Decodable, Sendable {
    let nickname: String?
    let profileText: String?
    let profileTextColor: String?
    let profileBackgroundColor: String?
    var profileImageUrl: OfficialProfileImage?

    var name: String {
        let name = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Komiic 用户" : name
    }
}

struct CommentPage: Sendable {
    let comments: [ComicComment]
    let nextOffset: Int?
}

extension KomiicAPI {
    private static let commentPageSize = 30
    private static let commentAuthorFields = "nickname profileText profileTextColor profileBackgroundColor profileImageUrl"

    func comicComments(comicID: String, offset: Int) async throws -> CommentPage {
        let data: ComicCommentsResult = try await perform("getMessagesByComicId", query: """
            query getMessagesByComicId($comicId: ID!, $pagination: Pagination!) {
                getMessagesByComicId(comicId: $comicId, pagination: $pagination) {
                    id comicId message deleted dateCreated upCount downCount
                    account { \(Self.commentAuthorFields) }
                    replyTo { message deleted account { \(Self.commentAuthorFields) } }
                }
            }
            """, variables: ["comicId": comicID, "pagination": [
                "limit": Self.commentPageSize, "offset": offset, "orderBy": "DATE_UPDATED", "asc": false
            ]])
        let rows = data.getMessagesByComicId
        return CommentPage(comments: rows.compactMap { $0 }.map(normalizedComment),
                           nextOffset: rows.count == Self.commentPageSize ? offset + rows.count : nil)
    }

    func myComments(offset: Int) async throws -> CommentPage {
        let data: MyCommentsResult = try await perform("myMessages", query: """
            query myMessages($limit: Int, $offset: Int) {
                myMessages(limit: $limit, offset: $offset) {
                    total
                    messages {
                        id comicId message deleted dateCreated upCount: upvotes downCount: downvotes
                        account { \(Self.commentAuthorFields) }
                        replyTo { message deleted account { \(Self.commentAuthorFields) } }
                    }
                }
            }
            """, variables: ["limit": Self.commentPageSize, "offset": offset])
        let page = data.myMessages
        let nextOffset = offset + page.messages.count
        return CommentPage(comments: page.messages.compactMap { $0 }.map(normalizedComment),
                           nextOffset: nextOffset > offset && nextOffset < page.total ? nextOffset : nil)
    }

    func commentVotes(comicID: String) async throws -> [String: Bool] {
        let data: CommentVotesResult = try await perform("messageVotesByComicId", query: """
            query messageVotesByComicId($comicId: ID!) {
                messageVotesByComicId(comicId: $comicId) { messageId up }
            }
            """, variables: ["comicId": comicID])
        return data.messageVotesByComicId.reduce(into: [:]) { votes, vote in
            if let vote { votes[vote.messageId] = vote.up }
        }
    }

    func postComment(comicID: String, message: String, replyingTo replyID: String?) async throws -> ComicComment {
        let data: PostedCommentResult = try await perform("addMessageToComic", query: """
            mutation addMessageToComic($comicId: ID!, $replyToId: ID!, $message: String!) {
                addMessageToComic(comicId: $comicId, replyToId: $replyToId, message: $message) {
                    id comicId message dateCreated reviewing
                    account { \(Self.commentAuthorFields) }
                    replyTo { message account { \(Self.commentAuthorFields) } }
                }
            }
            """, variables: ["comicId": comicID, "replyToId": replyID ?? "0", "message": message])
        return normalizedComment(data.addMessageToComic)
    }

    func voteOnComment(id: String, up: Bool) async throws {
        let _: CommentVoteMutationResult = try await perform("voteMessage", query: """
            mutation voteMessage($messageId: ID!, $up: Boolean!) {
                voteMessage(messageId: $messageId, up: $up)
            }
            """, variables: ["messageId": id, "up": up])
    }

    private func normalizedComment(_ comment: ComicComment) -> ComicComment {
        var result = comment
        if let url = result.account?.profileImageUrl?.url {
            result.account?.profileImageUrl?.url = normalizedURL(url)
        }
        if let url = result.replyTo?.account?.profileImageUrl?.url {
            result.replyTo?.account?.profileImageUrl?.url = normalizedURL(url)
        }
        return result
    }
}

private struct ComicCommentsResult: Decodable { let getMessagesByComicId: [ComicComment?] }
private struct MyCommentsResult: Decodable {
    let myMessages: Page

    struct Page: Decodable {
        let messages: [ComicComment?]
        let total: Int
    }
}
private struct CommentVotesResult: Decodable {
    let messageVotesByComicId: [Vote?]

    struct Vote: Decodable {
        let messageId: String
        let up: Bool
    }
}
private struct PostedCommentResult: Decodable { let addMessageToComic: ComicComment }
private struct CommentVoteMutationResult: Decodable {}
