//
//  NoteStore.swift
//  MarkdownEngine
//
//  A folder of `.md` files, either on this Mac or in the app's iCloud Drive
//  container. iCloud keeps that container in step across devices on its own;
//  this type only has to read and write through `NSFileCoordinator` and react
//  when files change underneath it. GitHub sync works on the same folder.
//

import AppKit
import Foundation

struct Note: Identifiable, Hashable {
    /// Path relative to the notes folder, e.g. `Ideas/Plan.md`.
    let relativePath: String
    let modified: Date

    var id: String { relativePath }
    var title: String { ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

enum StorageLocation: String, CaseIterable, Identifiable {
    case local, iCloud

    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: return "On this Mac"
        case .iCloud: return "iCloud Drive"
        }
    }
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var location: StorageLocation = .local
    @Published private(set) var rootURL: URL = NoteStore.localRoot
    @Published private(set) var isICloudAvailable = false
    @Published private(set) var isSwitchingLocation = false
    /// False until the storage location has been resolved at launch.
    @Published private(set) var isReady = false
    @Published var lastError: String?

    /// The open note.
    @Published var selection: String? {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }

    /// Contents of the open note, bound to the editor. Saved 1s after the last edit.
    @Published var text = "" {
        didSet { if text != savedText { scheduleSave() } }
    }

    /// What the open note holds on disk, as far as this store knows.
    private var savedText = ""
    private var saveTask: Task<Void, Never>?
    private var metadataQuery: NSMetadataQuery?
    private var queryObservers: [NSObjectProtocol] = []

    private static let locationKey = "notes.storageLocation"
    private static let seededKey = "notes.seededWelcome"

    nonisolated static let localRoot: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Markdown Notes", isDirectory: true)

    init() {
        let wanted = StorageLocation(rawValue: UserDefaults.standard.string(forKey: Self.locationKey) ?? "") ?? .local
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        Task { await bootstrap(wanted: wanted) }
    }

    private func bootstrap(wanted: StorageLocation) async {
        let container = await Self.iCloudDocumentsURL()
        isICloudAvailable = container != nil
        if wanted == .iCloud, let container {
            activate(.iCloud, root: container)
        } else {
            if wanted == .iCloud {
                lastError = "iCloud Drive isn't available, so notes are stored on this Mac for now."
            }
            activate(.local, root: Self.localRoot)
        }
        seedWelcomeNoteIfNeeded()
        isReady = true
    }

    // MARK: - Editing

    func createNote() {
        saveNow()
        var name = "Untitled.md"
        var counter = 2
        while FileManager.default.fileExists(atPath: url(for: name).path) {
            name = "Untitled \(counter).md"
            counter += 1
        }
        do {
            try writeFile(name, Data())
            notes = scanNotes()
            selection = name
        } catch {
            lastError = "Couldn't create a note: \(error.localizedDescription)"
        }
    }

    func rename(_ relativePath: String, to title: String) {
        let clean = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else { return }
        let folder = (relativePath as NSString).deletingLastPathComponent
        let newPath = folder.isEmpty ? "\(clean).md" : "\(folder)/\(clean).md"
        guard newPath != relativePath else { return }
        guard !FileManager.default.fileExists(atPath: url(for: newPath).path) else {
            lastError = "A note named “\(clean)” already exists."
            return
        }
        let wasSelected = selection == relativePath
        if wasSelected { saveNow() }
        do {
            try Self.coordinatedMove(from: url(for: relativePath), to: url(for: newPath))
            notes = scanNotes()
            if wasSelected { selection = newPath }
        } catch {
            lastError = "Couldn't rename the note: \(error.localizedDescription)"
        }
    }

    func delete(_ relativePath: String) {
        if selection == relativePath {
            saveTask?.cancel()
            savedText = text
            selection = nil
        }
        do {
            try trashFile(relativePath)
        } catch {
            lastError = "Couldn't move the note to the Trash: \(error.localizedDescription)"
        }
        notes = scanNotes()
    }

    /// Writes the open note now if it has unsaved edits.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let selection, text != savedText else { return }
        do {
            try writeFile(selection, Data(text.utf8))
            savedText = text
        } catch {
            lastError = "Couldn't save “\(selection)”: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func selectionChanged(from oldPath: String?) {
        saveTask?.cancel()
        if let oldPath, text != savedText {
            try? writeFile(oldPath, Data(text.utf8))
        }
        if let selection, let data = try? readFile(selection) {
            let contents = String(decoding: data, as: UTF8.self)
            savedText = contents
            text = contents
        } else {
            savedText = ""
            text = ""
        }
    }

    /// Re-reads the folder after something outside the editor changed it
    /// (iCloud, a GitHub pull). The open note follows the disk unless it has
    /// unsaved edits; then the edits win and the disk version is kept as a
    /// conflict copy, so nothing is lost either way.
    func reloadFromDisk() {
        notes = scanNotes()
        guard let selection else { return }
        guard FileManager.default.fileExists(atPath: url(for: selection).path) else {
            if text != savedText {
                saveNow()
                notes = scanNotes()
            } else {
                self.selection = nil
            }
            return
        }
        guard let data = try? readFile(selection) else { return }
        let disk = String(decoding: data, as: UTF8.self)
        guard disk != savedText else { return }
        if text == savedText {
            savedText = disk
            text = disk
        } else {
            let copy = Self.conflictPath(for: selection, existing: Set(notes.map(\.relativePath)), label: "conflict")
            try? writeFile(copy, data)
            savedText = disk
            saveNow()
            notes = scanNotes()
        }
    }

    // MARK: - Files

    func url(for relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func readFile(_ relativePath: String) throws -> Data {
        try Self.coordinatedRead(url(for: relativePath))
    }

    func writeFile(_ relativePath: String, _ data: Data) throws {
        try Self.coordinatedWrite(data, to: url(for: relativePath))
    }

    func trashFile(_ relativePath: String) throws {
        try Self.coordinatedTrash(url(for: relativePath))
    }

    private func scanNotes() -> [Note] {
        Self.markdownFiles(in: rootURL)
            .map { Note(relativePath: $0.relativePath, modified: $0.modified) }
            .sorted { $0.modified > $1.modified }
    }

    private func seedWelcomeNoteIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seededKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.seededKey)
        guard notes.isEmpty else { return }
        try? writeFile("Welcome.md", Data(sampleMarkdown.utf8))
        notes = scanNotes()
        selection = notes.first?.relativePath
    }

    // MARK: - Storage location

    /// Moves notes into iCloud Drive, or copies them back to this Mac. Leaving
    /// iCloud copies rather than moves: a move would delete the notes from
    /// every other device signed in to the same account.
    func setLocation(_ newLocation: StorageLocation) async {
        guard newLocation != location, !isSwitchingLocation else { return }
        isSwitchingLocation = true
        defer { isSwitchingLocation = false }
        saveNow()

        let destination: URL
        switch newLocation {
        case .local:
            destination = Self.localRoot
        case .iCloud:
            guard let container = await Self.iCloudDocumentsURL() else {
                isICloudAvailable = false
                lastError = "iCloud Drive isn't available. Sign in to iCloud and turn on iCloud Drive in System Settings."
                return
            }
            isICloudAvailable = true
            destination = container
        }

        let source = rootURL
        let intoICloud = newLocation == .iCloud
        let failures = await Task.detached {
            Self.transfer(from: source, to: destination, intoICloud: intoICloud)
        }.value
        activate(newLocation, root: destination)
        if failures > 0 {
            lastError = "\(failures) note(s) couldn't be moved and were left in \(source.path)."
        }
    }

    private func activate(_ newLocation: StorageLocation, root: URL) {
        saveNow()
        savedText = text
        selection = nil
        stopICloudMonitoring()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        location = newLocation
        rootURL = root
        UserDefaults.standard.set(newLocation.rawValue, forKey: Self.locationKey)
        notes = scanNotes()
        selection = notes.first?.relativePath
        if newLocation == .iCloud { startICloudMonitoring() }
    }

    nonisolated private static func transfer(from source: URL, to destination: URL, intoICloud: Bool) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var existing = Set(markdownFiles(in: destination).map(\.relativePath))
        var failures = 0
        for file in markdownFiles(in: source) {
            var relativePath = file.relativePath
            if existing.contains(relativePath) {
                let here = try? coordinatedRead(file.url)
                let there = try? coordinatedRead(destination.appendingPathComponent(relativePath))
                if here != nil, here == there {
                    if intoICloud { try? coordinatedTrash(file.url) }
                    continue
                }
                relativePath = conflictPath(for: relativePath, existing: existing, label: "from this Mac")
            }
            let target = destination.appendingPathComponent(relativePath)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if intoICloud {
                    try fm.setUbiquitous(true, itemAt: file.url, destinationURL: target)
                } else {
                    try coordinatedWrite(try coordinatedRead(file.url), to: target)
                }
                existing.insert(relativePath)
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// The `Documents` folder of the app's default iCloud container, or nil
    /// when the user isn't signed in or the app lacks the iCloud entitlement.
    nonisolated static func iCloudDocumentsURL() async -> URL? {
        await Task.detached { () -> URL? in
            let fm = FileManager.default
            guard fm.ubiquityIdentityToken != nil,
                  let container = fm.url(forUbiquityContainerIdentifier: nil) else { return nil }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        }.value
    }

    // MARK: - iCloud monitoring

    private func startICloudMonitoring() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.iCloudQueryUpdated() }
            })
        }
        metadataQuery = query
        query.start()
    }

    private func stopICloudMonitoring() {
        metadataQuery?.stop()
        metadataQuery = nil
        queryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        queryObservers.removeAll()
    }

    private func iCloudQueryUpdated() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        // Ask iCloud to fetch anything that exists only as a placeholder, so
        // notes edited on another device are readable here.
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        reloadFromDisk()
    }

    // MARK: - Coordinated file access

    nonisolated static func markdownFiles(in root: URL) -> [(relativePath: String, url: URL, modified: Date)] {
        let rootPath = root.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [(relativePath: String, url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            files.append((String(path.dropFirst(rootPath.count + 1)), url, values?.contentModificationDate ?? .distantPast))
        }
        return files
    }

    /// Every note in `root`, keyed by relative path. Throws if any note can't
    /// be read: a sync must never mistake an unreadable note for a deleted one.
    nonisolated static func readAllMarkdown(in root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in markdownFiles(in: root) {
            result[file.relativePath] = try coordinatedRead(file.url)
        }
        return result
    }

    /// `Folder/Title (label 2026-10-12 1530).md`, numbered if that is taken too.
    nonisolated static func conflictPath(for relativePath: String, existing: Set<String>, label: String) -> String {
        let folder = (relativePath as NSString).deletingLastPathComponent
        let title = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())
        var counter = 1
        while true {
            let suffix = counter == 1 ? "" : " \(counter)"
            let name = "\(title) (\(label) \(stamp)\(suffix)).md"
            let candidate = folder.isEmpty ? name : "\(folder)/\(name)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    nonisolated static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    nonisolated static func coordinatedTrash(_ url: URL) throws {
        var coordinationError: NSError?
        var trashError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { trashError = error }
        }
        if let coordinationError { throw coordinationError }
        if let trashError { throw trashError }
    }

    nonisolated static func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { source, destination in
            do { try FileManager.default.moveItem(at: source, to: destination) } catch { moveError = error }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }
}
