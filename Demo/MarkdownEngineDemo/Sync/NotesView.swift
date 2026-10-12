//
//  NotesView.swift
//  MarkdownEngine
//
//  Sidebar of notes next to the editor, plus a sync button and status.
//

import SwiftUI

struct NotesView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var github: GitHubSync

    @State private var renaming: Note?
    @State private var newName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        } detail: {
            if let selection = store.selection {
                ContentView(text: $store.text, documentId: selection)
                    .navigationTitle((selection as NSString).deletingPathExtension)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "doc.text",
                    description: Text("Pick a note in the sidebar or press ⌘N.")
                )
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $store.selection) {
            ForEach(store.notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).lineLimit(1)
                    if !note.folder.isEmpty {
                        Text(note.folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(note.relativePath)
                .contextMenu {
                    Button("Rename…") {
                        newName = note.title
                        renaming = note
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url(for: note.relativePath)])
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        store.delete(note.relativePath)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { syncStatus }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.createNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New note (⌘N)")

                Button {
                    Task { await github.syncNow() }
                } label: {
                    Label("Sync with GitHub", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(github.status == .syncing)
                .help(github.isConfigured ? "Sync with GitHub now" : "Set up GitHub sync in Settings")

                SettingsLink {
                    Label("Sync Settings", systemImage: "gearshape")
                }
                .help("Storage and sync settings")
            }
        }
        .alert("Rename Note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { store.rename(renaming.relativePath, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(store.location.label, systemImage: store.location == .iCloud ? "icloud" : "internaldrive")
            SyncStatusText()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One line describing the last GitHub sync.
struct SyncStatusText: View {
    @EnvironmentObject private var github: GitHubSync

    var body: some View {
        switch github.status {
        case .syncing:
            Label("Syncing with GitHub…", systemImage: "arrow.triangle.2.circlepath")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .lineLimit(3)
        case .idle:
            if let lastSync = github.lastSync {
                Label {
                    Text("GitHub: \(github.lastSummary ?? "synced"), \(lastSync, style: .relative) ago")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } else if github.isConfigured {
                Label("GitHub: not synced yet", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("GitHub sync is off", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}
