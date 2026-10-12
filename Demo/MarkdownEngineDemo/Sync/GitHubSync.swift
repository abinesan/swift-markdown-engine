//
//  GitHubSync.swift
//  MarkdownEngine
//
//  Two-way sync between the notes folder and a folder in a GitHub repository,
//  over the REST API (no git binary, no clone).
//
//  Each sync compares three versions of every note by git blob SHA: the local
//  file, the file on GitHub, and the version both sides agreed on at the last
//  sync ("base"). Whichever side moved away from base wins; if both did, the
//  GitHub version takes the note's name and the local version is kept as a
//  conflict copy, which is uploaded too. Local changes go up as one commit.
//

import CryptoKit
import Foundation
import Security

struct GitHubRepoConfig: Codable, Equatable {
    /// `owner/repo`
    var repository = ""
    var branch = "main"
    /// Folder inside the repository that holds the notes; empty for the root.
    var folder = ""

    var owner: String { parts.first ?? "" }
    var repo: String { parts.count == 2 ? parts[1] : "" }
    var isComplete: Bool { parts.count == 2 && !owner.isEmpty && !repo.isEmpty && !trimmedBranch.isEmpty }
    var trimmedBranch: String { branch.trimmingCharacters(in: .whitespaces) }
    var normalizedFolder: String {
        folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "/")
    }

    private var parts: [String] {
        repository.trimmingCharacters(in: .whitespaces)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }
}

enum GitHubSyncError: LocalizedError {
    case notConfigured
    case missingBranch(String, String)
    case http(Int, String)
    case treeTooLarge
    case remoteMoved
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a repository and an access token in Settings."
        case let .missingBranch(repository, branch):
            return "Couldn't find branch “\(branch)” in \(repository). Check the name and that the token can access it. An empty repository needs one commit first (add a README on GitHub)."
        case let .http(status, message):
            if status == 401 { return "GitHub rejected the access token. Check it in Settings." }
            return "GitHub error \(status): \(message)"
        case .treeTooLarge:
            return "The repository is too large to sync through the API. Use a smaller repository for notes."
        case .remoteMoved:
            return "The branch kept changing on GitHub while syncing. Try again."
        case .invalidResponse:
            return "GitHub sent a response this app didn't understand."
        }
    }
}

struct SyncSummary {
    var uploaded = 0
    var downloaded = 0
    var deletedHere = 0
    var deletedOnGitHub = 0
    var conflicts = 0

    var description: String {
        var parts: [String] = []
        if uploaded > 0 { parts.append("\(uploaded) up") }
        if downloaded > 0 { parts.append("\(downloaded) down") }
        if deletedHere + deletedOnGitHub > 0 { parts.append("\(deletedHere + deletedOnGitHub) deleted") }
        if conflicts > 0 { parts.append("\(conflicts) conflict copies") }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")
    }
}

@MainActor
final class GitHubSync: ObservableObject {
    enum Status: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    @Published var config: GitHubRepoConfig {
        didSet { if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.configKey) } }
    }
    @Published var token: String {
        didSet { Keychain.write(token, account: Self.tokenAccount) }
    }
    @Published var autoSync: Bool {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: Self.autoSyncKey)
            restartAutoSync()
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSummary: String?

    var isConfigured: Bool { config.isComplete && !token.isEmpty }

    private let store: NoteStore
    private var autoSyncTask: Task<Void, Never>?

    private static let configKey = "github.config"
    private static let autoSyncKey = "github.autoSync"
    private static let stateKey = "github.syncState"
    private static let tokenAccount = "github-token"
    private static let autoSyncInterval: Duration = .seconds(300)

    init(store: NoteStore) {
        self.store = store
        let defaults = UserDefaults.standard
        config = defaults.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(GitHubRepoConfig.self, from: $0) } ?? GitHubRepoConfig()
        token = Keychain.read(account: Self.tokenAccount) ?? ""
        autoSync = defaults.bool(forKey: Self.autoSyncKey)
        restartAutoSync()
    }

    func syncNow() async {
        guard status != .syncing else { return }
        guard isConfigured else {
            status = .failed(GitHubSyncError.notConfigured.localizedDescription)
            return
        }
        while !store.isReady { try? await Task.sleep(for: .milliseconds(200)) }

        status = .syncing
        do {
            let summary = try await runSyncRetrying()
            lastSync = Date()
            lastSummary = summary.description
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func restartAutoSync() {
        autoSyncTask?.cancel()
        guard autoSync else { return }
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.isConfigured { await self.syncNow() }
                try? await Task.sleep(for: Self.autoSyncInterval)
            }
        }
    }

    // MARK: - Sync

    private func runSyncRetrying() async throws -> SyncSummary {
        for attempt in 0..<3 {
            do {
                return try await runSync()
            } catch GitHubSyncError.remoteMoved where attempt < 2 {
                continue
            }
        }
        throw GitHubSyncError.remoteMoved
    }

    private func runSync() async throws -> SyncSummary {
        store.saveNow()
        let config = config
        let api = try GitHubAPI(owner: config.owner, repo: config.repo, token: token)
        let prefix = config.normalizedFolder.isEmpty ? "" : config.normalizedFolder + "/"
        let root = store.rootURL
        let stateKey = "\(config.owner)/\(config.repo)@\(config.trimmedBranch):\(config.normalizedFolder)|\(root.path)"

        let local = try await Task.detached { try NoteStore.readAllMarkdown(in: root) }.value
        let localSHA = local.mapValues(gitBlobSHA)

        let head = try await api.head(branch: config.trimmedBranch, repository: config.repository)
        let tree = try await api.tree(head.treeSHA)
        var remote: [String: String] = [:]
        for entry in tree where entry.type == "blob" && entry.path.hasPrefix(prefix) && entry.path.lowercased().hasSuffix(".md") {
            let relativePath = String(entry.path.dropFirst(prefix.count))
            // The local scan skips hidden files and folders; match it.
            if relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            remote[relativePath] = entry.sha
        }
        let base = Self.loadBase(for: stateKey)

        var uploads: [String: Data] = [:]
        var remoteDeletes: [String] = []
        var downloads: [String: String] = [:]
        var localDeletes: [String] = []
        var conflictCopies: [String: Data] = [:]
        var taken = Set(local.keys).union(remote.keys)

        for path in Set(local.keys).union(remote.keys) {
            let here = localSHA[path], there = remote[path], agreed = base[path]
            if here == there { continue }
            if here == agreed {
                // Changed on GitHub only.
                if let there { downloads[path] = there } else { localDeletes.append(path) }
            } else if there == agreed {
                // Changed here only.
                if let data = local[path] { uploads[path] = data } else { remoteDeletes.append(path) }
            } else if let there, let data = local[path] {
                // Changed on both sides: keep both.
                let copy = NoteStore.conflictPath(for: path, existing: taken, label: "conflict")
                taken.insert(copy)
                downloads[path] = there
                conflictCopies[copy] = data
                uploads[copy] = data
            } else if let there {
                // Deleted here, edited on GitHub: keep the edit.
                downloads[path] = there
            } else if let data = local[path] {
                // Deleted on GitHub, edited here: keep the edit.
                uploads[path] = data
            }
        }

        // Fetch everything before touching the disk, so a failed request
        // leaves the folder as it was.
        var downloaded: [String: Data] = [:]
        for (path, sha) in downloads {
            downloaded[path] = try await api.blob(sha)
        }

        if !uploads.isEmpty || !remoteDeletes.isEmpty {
            var entries: [GitHubAPI.TreeEntry] = []
            for (path, data) in uploads {
                let sha = try await api.createBlob(data)
                entries.append(.init(path: prefix + path, sha: sha))
            }
            for path in remoteDeletes {
                entries.append(.init(path: prefix + path, sha: nil))
            }
            let newTree = try await api.createTree(base: head.treeSHA, entries: entries)
            let commit = try await api.createCommit(
                message: commitMessage(uploads: uploads.count, deletes: remoteDeletes.count),
                tree: newTree, parent: head.sha
            )
            try await api.updateBranch(config.trimmedBranch, to: commit)
        }

        for (path, data) in downloaded { try store.writeFile(path, data) }
        for (path, data) in conflictCopies { try store.writeFile(path, data) }
        for path in localDeletes { try store.trashFile(path) }
        store.reloadFromDisk()

        var newBase = remote
        for (path, data) in uploads { newBase[path] = gitBlobSHA(data) }
        for path in remoteDeletes { newBase[path] = nil }
        Self.saveBase(newBase, for: stateKey)

        return SyncSummary(
            uploaded: uploads.count - conflictCopies.count,
            downloaded: downloads.count,
            deletedHere: localDeletes.count,
            deletedOnGitHub: remoteDeletes.count,
            conflicts: conflictCopies.count
        )
    }

    private func commitMessage(uploads: Int, deletes: Int) -> String {
        let device = Host.current().localizedName ?? "Mac"
        var parts: [String] = []
        if uploads > 0 { parts.append("\(uploads) updated") }
        if deletes > 0 { parts.append("\(deletes) deleted") }
        return "Sync notes from \(device): \(parts.joined(separator: ", "))"
    }

    // Only the state for the current repository + folder is kept; changing
    // either starts over with an empty base, which can only produce conflict
    // copies, never lost notes.
    private static func loadBase(for key: String) -> [String: String] {
        let stored = UserDefaults.standard.dictionary(forKey: stateKey)
        guard stored?["key"] as? String == key else { return [:] }
        return stored?["files"] as? [String: String] ?? [:]
    }

    private static func saveBase(_ files: [String: String], for key: String) {
        let state: [String: Any] = ["key": key, "files": files]
        UserDefaults.standard.set(state, forKey: stateKey)
    }
}

/// The SHA git gives a file's contents, so local files compare directly
/// against the SHAs GitHub reports.
private func gitBlobSHA(_ data: Data) -> String {
    var hasher = Insecure.SHA1()
    hasher.update(data: Data("blob \(data.count)\0".utf8))
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - GitHub REST API

private struct GitHubAPI {
    struct Head {
        let sha: String
        let treeSHA: String
    }

    struct TreeEntry: Encodable {
        let path: String
        /// nil deletes the file.
        let sha: String?

        enum CodingKeys: String, CodingKey { case path, mode, type, sha }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode("100644", forKey: .mode)
            try container.encode("blob", forKey: .type)
            if let sha { try container.encode(sha, forKey: .sha) } else { try container.encodeNil(forKey: .sha) }
        }
    }

    struct SHA: Decodable { let sha: String }
    struct Ref: Decodable { let object: SHA }
    struct Commit: Decodable { let sha: String; let tree: SHA }
    struct Tree: Decodable {
        struct Entry: Decodable { let path: String; let type: String; let sha: String }
        let tree: [Entry]
        let truncated: Bool
    }
    struct Blob: Decodable { let content: String; let encoding: String }
    struct ErrorBody: Decodable { let message: String }

    private let baseURL: URL
    private let token: String

    init(owner: String, repo: String, token: String) throws {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/") else {
            throw GitHubSyncError.notConfigured
        }
        baseURL = url
        self.token = token
    }

    func head(branch: String, repository: String) async throws -> Head {
        let ref: Ref
        do {
            ref = try await call("GET", "git/ref/heads/\(escaped(branch))")
        } catch GitHubSyncError.http(let status, _) where status == 404 || status == 409 {
            throw GitHubSyncError.missingBranch(repository, branch)
        }
        let commit: Commit = try await call("GET", "git/commits/\(ref.object.sha)")
        return Head(sha: commit.sha, treeSHA: commit.tree.sha)
    }

    func tree(_ sha: String) async throws -> [Tree.Entry] {
        let tree: Tree = try await call("GET", "git/trees/\(sha)?recursive=1")
        // A truncated listing would make missing files look deleted.
        if tree.truncated { throw GitHubSyncError.treeTooLarge }
        return tree.tree
    }

    func blob(_ sha: String) async throws -> Data {
        let blob: Blob = try await call("GET", "git/blobs/\(sha)")
        if blob.encoding == "base64" {
            guard let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters) else {
                throw GitHubSyncError.invalidResponse
            }
            return data
        }
        return Data(blob.content.utf8)
    }

    func createBlob(_ data: Data) async throws -> String {
        let body = ["content": data.base64EncodedString(), "encoding": "base64"]
        let result: SHA = try await call("POST", "git/blobs", body: body)
        return result.sha
    }

    func createTree(base: String, entries: [TreeEntry]) async throws -> String {
        struct Body: Encodable { let base_tree: String; let tree: [TreeEntry] }
        let result: SHA = try await call("POST", "git/trees", body: Body(base_tree: base, tree: entries))
        return result.sha
    }

    func createCommit(message: String, tree: String, parent: String) async throws -> String {
        struct Body: Encodable { let message: String; let tree: String; let parents: [String] }
        let result: SHA = try await call("POST", "git/commits", body: Body(message: message, tree: tree, parents: [parent]))
        return result.sha
    }

    /// Fast-forward only. If someone pushed since this sync read the branch,
    /// GitHub answers 422 and the whole sync runs again on the new head.
    func updateBranch(_ branch: String, to commit: String) async throws {
        struct Body: Encodable { let sha: String; let force: Bool }
        do {
            let _: Ref = try await call("PATCH", "git/refs/heads/\(escaped(branch))", body: Body(sha: commit, force: false))
        } catch GitHubSyncError.http(let status, _) where status == 422 {
            throw GitHubSyncError.remoteMoved
        }
    }

    private func call<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try await send(method, path, json: nil)
    }

    private func call<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body) async throws -> Response {
        try await send(method, path, json: try JSONEncoder().encode(body))
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, json: Data?) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw GitHubSyncError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw GitHubSyncError.http(status, message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubSyncError.invalidResponse
        }
    }

    private func escaped(_ branch: String) -> String {
        branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
    }
}

// MARK: - Keychain

private enum Keychain {
    private static let service = "MarkdownEngineDemo.GitHubSync"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
