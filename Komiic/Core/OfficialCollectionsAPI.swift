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
        let schema = try await collectionSchema()
        guard let field = schema.mutationType?.fields.first(where: {
            $0.name.lowercased().contains("folder") && $0.argumentsContain("folderId", "name")
                && ($0.name.lowercased().contains("rename") || $0.name.lowercased().contains("update"))
                && $0.canCall(with: ["folderId", "name"])
        }) else { throw KomiicError.graphQL("官网暂未提供可用的书柜更名接口。") }
        let _: CollectionValue = try await callCollectionField(field, mutation: true, variables: ["folderId": id, "name": name])
    }

    func blockedCollection() async throws -> OfficialBlockedCollection {
        let schema = try await collectionSchema()
        // Resolve from the service's own schema instead of assuming a block-list API name.
        guard let field = schema.queryType.fields.first(where: {
            $0.isComicBlock && $0.type.isList && $0.canCall(with: ["pagination"])
        }) else { throw KomiicError.graphQL("官网屏蔽列表接口暂不可用，本次未更新屏蔽数据。") }
        let selection: String
        let rowKey: String?
        if field.type.base.kind == "OBJECT" {
            let type: CollectionTypeResult = try await perform("AppCollectionType", query: """
                query AppCollectionType($name: String!) { __type(name: $name) { fields { name } } }
                """, variables: ["name": field.type.base.name ?? ""])
            let names = Set(type.__type?.fields.map(\.name) ?? [])
            if names.contains("comicId") { rowKey = "comicId"; selection = "comicId" }
            else if names.contains("id"), names.contains("title") { rowKey = "id"; selection = "id" }
            else { throw KomiicError.invalidResponse }
        } else { rowKey = nil; selection = "" }
        var ids: Set<String> = []
        var offset = 0
        while true {
            var variables: [String: Any] = [:]
            if field.args.contains(where: { $0.name == "pagination" }) {
                variables["pagination"] = ["offset": offset, "limit": Self.pageSize, "orderBy": "DATE_UPDATED", "asc": false]
            }
            let result = try await callCollectionField(field, mutation: false, variables: variables, selection: selection)
            guard case .array(let rows) = result.value else { throw KomiicError.invalidResponse }
            let page = rows.compactMap { rowKey == nil ? $0.string : $0.object?[rowKey!]?.string }
            let additions = page.filter { ids.insert($0).inserted }
            if variables.isEmpty || rows.count < Self.pageSize || additions.isEmpty { break }
            offset += rows.count
        }
        // Preserve IDs even when a deleted or restricted comic has no readable metadata.
        return OfficialBlockedCollection(ids: ids, comics: (try? await comics(ids: ids.sorted())) ?? [])
    }

    func setBlocked(comicID: String, blocked: Bool) async throws {
        let schema = try await collectionSchema()
        let fields = schema.mutationType?.fields ?? []
        guard let field = fields.first(where: { field in
            let name = field.name.lowercased()
            let removes = ["unblock", "remove", "delete"].contains { name.contains($0) }
            let setsValue = field.args.contains { $0.name == "blocked" && $0.type.base.name == "Boolean" }
            return field.isComicBlock && field.argumentsContain("comicId")
                && (setsValue || removes == !blocked) && field.canCall(with: ["comicId", "blocked"])
        }) else { throw KomiicError.graphQL("官网屏蔽操作接口暂不可用，下拉刷新后会重试。") }
        var variables: [String: Any] = ["comicId": comicID]
        if field.args.contains(where: { $0.name == "blocked" }) { variables["blocked"] = blocked }
        let _: CollectionValue = try await callCollectionField(field, mutation: true, variables: variables)
    }

    private func collectionSchema() async throws -> CollectionSchema {
        try await CollectionSchemaCache.shared.schema(origin: baseURL) {
            let ref = "kind name ofType { kind name ofType { kind name ofType { kind name } } }"
            let fields = "fields { name args { name defaultValue type { \(ref) } } type { \(ref) } }"
            let result: CollectionSchemaResult = try await perform("AppCollectionSchema", query:
                "query AppCollectionSchema { __schema { queryType { \(fields) } mutationType { \(fields) } } }", variables: [:])
            return result.__schema
        }
    }

    private func callCollectionField(_ field: CollectionField, mutation: Bool, variables: [String: Any],
                                     selection: String? = nil) async throws -> CollectionValue {
        let args = field.args.filter { variables[$0.name] != nil }
        let declarations = args.map { "$\($0.name): \($0.type.signature)" }.joined(separator: ", ")
        let references = args.map { "\($0.name): $\($0.name)" }.joined(separator: ", ")
        let definition = declarations.isEmpty ? "" : "(\(declarations))"
        let arguments = references.isEmpty ? "" : "(\(references))"
        let selected = selection ?? (field.type.base.kind == "OBJECT" ? "__typename" : "")
        let fields = selected.isEmpty ? "" : " { \(selected) }"
        return try await perform("AppCollectionOperation", query:
            "\(mutation ? "mutation" : "query") AppCollectionOperation\(definition) { value: \(field.name)\(arguments)\(fields) }", variables: variables)
    }
}

private struct FolderRow: Decodable { let id: String; let name: String }
private struct FolderListResult: Decodable { let folders: [FolderRow?] }
private struct CreateFolderResult: Decodable { let createFolder: FolderRow }
private struct FolderIDsResult: Decodable {
    let folderComicIds: IDs
    struct IDs: Decodable { let comicIds: [String] }
}
private struct CollectionMutationResult: Decodable {}
private struct CollectionSchemaResult: Decodable { let __schema: CollectionSchema }
private struct CollectionSchema: Decodable {
    let queryType: Fields
    let mutationType: Fields?
    struct Fields: Decodable { let fields: [CollectionField] }
}
private struct CollectionTypeResult: Decodable {
    let __type: Fields?
    struct Fields: Decodable { let fields: [Field] }
    struct Field: Decodable { let name: String }
}
private struct CollectionField: Decodable {
    let name: String
    let args: [Argument]
    let type: CollectionTypeReference
    struct Argument: Decodable {
        let name: String
        let defaultValue: String?
        let type: CollectionTypeReference
    }
    var isComicBlock: Bool {
        let text = name.lowercased()
        return text.contains("block") && (text.contains("comic") || (type.base.name ?? "").lowercased().contains("comic"))
    }
    func argumentsContain(_ names: String...) -> Bool { names.allSatisfy { name in args.contains { $0.name == name } } }
    func canCall(with names: Set<String>) -> Bool {
        args.allSatisfy { $0.type.kind != "NON_NULL" || $0.defaultValue != nil || names.contains($0.name) }
    }
}
private final class CollectionTypeReference: Decodable, @unchecked Sendable {
    let kind: String
    let name: String?
    let ofType: CollectionTypeReference?
    var base: CollectionTypeReference { ofType?.base ?? self }
    var isList: Bool { kind == "LIST" || (ofType?.isList ?? false) }
    var signature: String {
        if kind == "NON_NULL" { return (ofType?.signature ?? "ID") + "!" }
        if kind == "LIST" { return "[\(ofType?.signature ?? "ID")]" }
        return name ?? "ID"
    }
}
private actor CollectionSchemaCache {
    static let shared = CollectionSchemaCache()
    private var tasks: [URL: Task<CollectionSchema, Error>] = [:]
    func schema(origin: URL, load: @escaping @Sendable () async throws -> CollectionSchema) async throws -> CollectionSchema {
        if let task = tasks[origin] { return try await task.value }
        let task = Task { try await load() }
        tasks[origin] = task
        do { return try await task.value }
        catch { tasks[origin] = nil; throw error }
    }
}
private struct CollectionValue: Decodable { let value: CollectionJSON }
private indirect enum CollectionJSON: Decodable {
    case string(String), array([CollectionJSON]), object([String: CollectionJSON]), other
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: CollectionJSON]? { if case .object(let value) = self { return value }; return nil }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Int.self) { self = .string(String(value)) }
        else if let value = try? c.decode([CollectionJSON].self) { self = .array(value) }
        else if let value = try? c.decode([String: CollectionJSON].self) { self = .object(value) }
        else if c.decodeNil() || (try? c.decode(Bool.self)) != nil { self = .other }
        else { throw KomiicError.invalidResponse }
    }
}
