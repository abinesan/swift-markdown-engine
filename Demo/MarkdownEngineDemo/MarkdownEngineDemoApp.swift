//
//  MarkdownEngineDemoApp.swift
//  MarkdownEngine
//
//  Created by Nicolas von Mallinckrodt on 29.04.26.
//

import SwiftUI

@main
@MainActor
struct MarkdownEngineDemoApp: App {
    @StateObject private var store: NoteStore
    @StateObject private var github: GitHubSync

    init() {
        let store = NoteStore()
        _store = StateObject(wrappedValue: store)
        _github = StateObject(wrappedValue: GitHubSync(store: store))
    }

    var body: some Scene {
        WindowGroup("MarkdownEngine Demo") {
            NotesView()
                .frame(minWidth: 820, minHeight: 480)
                .environmentObject(store)
                .environmentObject(github)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { store.createNote() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Sync with GitHub") { Task { await github.syncNow() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        Settings {
            SyncSettingsView()
                .environmentObject(store)
                .environmentObject(github)
        }
    }
}
