import Foundation

extension KomiicAPI {
    func bookshelves() async throws -> [Bookshelf] {
        let data: FolderListResult = try await perform("myFolder", query:
            "query myFolder { folders { id name } }", variables: [:])
        let folders = data.folders.compactMap { $0 }
        // Bound concurrency so large libraries do not flood the account's origin.
        return try await withThrowingTaskGroup(of: (Int, Bookshelf).self) { group in
            var result = Array<Bookshelf?>(repeating: nil, count: folders.count)
            var next = 0
            for index in 0..<min(4, folders.count) {
                group.addTask { (index, try await loadBookshelf(folders[index])) }
                next += 1
            }
            while let (index, shelf) = try await group.next() {
                result[index] = shelf
                if next < folders.count {
                    let index = next
                    group.addTask { (index, try await loadBookshelf(folders[index])) }
                    next += 1
                }
            }
            return result.compactMap { $0 }
        }
    }

    private func loadBookshelf(_ folder: FolderRow) async throws -> Bookshelf {
        var shelf = Bookshelf.official(id: folder.id, name: folder.name)
        var seen: Set<String> = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page: FolderIDsResult = try await perform("folderComicIds", query: """
                query folderComicIds($folderId: ID!, $pagination: Pagination!) {
                    folderComicIds(folderId: $folderId, pagination: $pagination) { comicIds }
                }
                """, variables: ["folderId": folder.id, "pagination": ["limit": Self.pageSize,
                    "offset": offset, "orderBy": "DATE_UPDATED", "asc": false]])
            let ids = page.folderComicIds.comicIds
            let additions = ids.filter { seen.insert($0).inserted }
            guard !additions.isEmpty else { break }
            shelf.comics += try await comics(ids: additions)
            if ids.count < Self.pageSize { break }
            offset += ids.count
        }
        return shelf
    }

    func createBookshelf(name: String) async throws -> Bookshelf {
        let result: CreateFolderResult = try await perform("createFolder", query:
            "mutation createFolder($name: String!) { createFolder(name: $name) { id name } }", variables: ["name": name])
        return Bookshelf.official(id: result.createFolder.id, name: result.createFolder.name)
    }

    func deleteBookshelf(id: String) async throws {
        let _: CollectionMutationResult = try await perform("removeFolder", query:
            "mutation removeFolder($folderId: ID!) { removeFolder(folderId: $folderId) }", variables: ["folderId": id])
    }

    func setBookshelfComic(shelfID: String, comicID: String, adding: Bool) async throws {
        // removeComicToFolder is the name used by the first-party folder API.
        let name = adding ? "addComicToFolder" : "removeComicToFolder"
        let _: CollectionMutationResult = try await perform(name, query:
            "mutation \(name)($comicId: ID!, $folderId: ID!) { \(name)(comicId: $comicId, folderId: $folderId) }",
            variables: ["comicId": comicID, "folderId": shelfID])
    }

    func renameBookshelf(id: String, name: String) async throws {
        let _: CollectionMutationResult = try await perform("updateFolderName", query: """
            mutation updateFolderName($folderId: ID!, $name: String!) {
                updateFolderName(folderId: $folderId, name: $name)
            }
            """, variables: ["folderId": id, "name": name])
    }

    func blockedCollection() async throws -> OfficialBlockedCollection {
        let data: BlockedIDsResult = try await perform("blockedComicIds", query:
            "query blockedComicIds { blockedComicIds }", variables: [:])
        let ids = Set(data.blockedComicIds)
        // A missing/deleted comic must never discard its block ID.
        return OfficialBlockedCollection(ids: ids, comics: (try? await comics(ids: ids.sorted())) ?? [])
    }

    func setBlocked(comicID: String, blocked: Bool) async throws {
        let operation = blocked ? "blockComic" : "unblockComic"
        let _: CollectionMutationResult = try await perform(operation, query:
            "mutation \(operation)($comicId: ID!) { \(operation)(comicId: $comicId) }", variables: ["comicId": comicID])
    }
}

private struct FolderRow: Decodable { let id: String; let name: String }
private struct FolderListResult: Decodable { let folders: [FolderRow?] }
private struct CreateFolderResult: Decodable { let createFolder: FolderRow }
private struct FolderIDsResult: Decodable {
    let folderComicIds: IDs
    struct IDs: Decodable { let comicIds: [String] }
}
private struct BlockedIDsResult: Decodable { let blockedComicIds: [String] }
private struct CollectionMutationResult: Decodable {}
