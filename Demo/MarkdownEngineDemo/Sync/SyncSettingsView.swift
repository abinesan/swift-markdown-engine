//
//  SyncSettingsView.swift
//  MarkdownEngine
//
//  Settings window (⌘,): where notes live, and the GitHub repository they
//  sync with.
//

import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var github: GitHubSync

    var body: some View {
        Form {
            Section("Storage") {
                Picker("Keep notes", selection: locationBinding) {
                    ForEach(StorageLocation.allCases) { location in
                        Text(location.label).tag(location)
                    }
                }
                .disabled(store.isSwitchingLocation)

                if store.isSwitchingLocation {
                    ProgressView("Moving notes…").controlSize(.small)
                } else if !store.isICloudAvailable {
                    Text("iCloud Drive isn't available. Sign in to iCloud on this Mac, and give the app the iCloud capability in Xcode (see Sync/README.md).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Folder") {
                    HStack {
                        Text(store.rootURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.rootURL])
                        }
                    }
                }
            }

            Section("GitHub") {
                TextField("Repository", text: $github.config.repository, prompt: Text("owner/repo"))
                TextField("Branch", text: $github.config.branch, prompt: Text("main"))
                TextField("Folder in repository", text: $github.config.folder, prompt: Text("Repository root"))
                SecureField("Access token", text: $github.token)
                Text("Use a fine-grained personal access token limited to this repository, with Contents set to Read and write. It's stored in your keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Sync automatically every 5 minutes", isOn: $github.autoSync)
                HStack(alignment: .firstTextBaseline) {
                    Button("Sync Now") {
                        Task { await github.syncNow() }
                    }
                    .disabled(github.status == .syncing || !github.isConfigured)
                    SyncStatusText()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var locationBinding: Binding<StorageLocation> {
        Binding(
            get: { store.location },
            set: { newLocation in Task { await store.setLocation(newLocation) } }
        )
    }
}
