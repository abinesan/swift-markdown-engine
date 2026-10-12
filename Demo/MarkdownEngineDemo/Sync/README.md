# Notes, iCloud sync and GitHub sync

The demo app keeps notes as plain `.md` files in one folder and can sync that
folder two ways. They work independently and can be used together.

| File | What it does |
|---|---|
| `NoteStore.swift` | The notes folder: list, open, save (1s after typing stops), create, rename, trash. Lives on this Mac or in iCloud Drive. |
| `GitHubSync.swift` | Two-way sync with a folder in a GitHub repository over the REST API. |
| `NotesView.swift` | Sidebar + editor window, sync button and status. |
| `SyncSettingsView.swift` | Settings window (⌘,): storage location and GitHub repository. |

## Where notes live

- **On this Mac** (default): `~/Documents/Markdown Notes`
- **iCloud Drive**: the `Documents` folder of the app's iCloud container.
  Switching to iCloud moves the notes in. Switching back copies them out and
  leaves the iCloud copies alone, because a move would delete them from your
  other devices.

## Turning on iCloud

iCloud needs a signed app, so set this up once in Xcode:

1. Select the **MarkdownEngineDemo** target → **Signing & Capabilities**.
2. Pick your **Team** and change the **Bundle Identifier** to one you own
   (e.g. `com.abinesan.MarkdownNotes`).
3. **+ Capability → iCloud**. Tick **iCloud Documents** and add a container
   (e.g. `iCloud.com.abinesan.MarkdownNotes`).
4. Build and run, then open Settings (⌘,) and set **Keep notes** to
   **iCloud Drive**.

Without those steps the app runs as before and stores notes on this Mac;
Settings says iCloud isn't available.

Other devices see changes once iCloud uploads them, usually within seconds.
The app watches the container and reloads notes that change. If a note you're
editing changes elsewhere before your edit is saved, your version is kept and
the other one is saved next to it as `Title (conflict …).md`.

## Turning on GitHub sync

1. Create a repository on GitHub (private is fine) with at least one commit.
   Adding a README when you create it is enough.
2. Create a **fine-grained personal access token**: GitHub → Settings →
   Developer settings → Fine-grained tokens. Give it access to that repository
   only, with **Contents: Read and write**.
3. In the app's Settings, fill in the repository (`owner/repo`), the branch,
   optionally a folder inside the repository, and the token. The token is
   stored in the keychain.
4. Press **Sync Now** (or ⇧⌘S), or turn on automatic sync every 5 minutes.

### How a sync decides what to do

For every `.md` file it compares three versions by git blob SHA: the local
file, the file on GitHub, and the version both sides had after the last sync.

| Local | GitHub | Result |
|---|---|---|
| unchanged | changed | download |
| unchanged | deleted | move the local file to the Trash |
| changed | unchanged | upload |
| deleted | unchanged | delete on GitHub |
| changed | changed | GitHub's version keeps the name; yours is saved and uploaded as `Title (conflict …).md` |
| deleted | changed | keep the GitHub edit |
| changed | deleted | keep your edit |

All uploads and deletes go up as **one commit**. If someone pushes to the
branch while a sync is running, the sync starts over on the new commit
(up to three tries) rather than overwriting it. Nothing on disk changes until
every download has arrived.

The first sync with a repository has no previous version to compare against,
so a note that differs on the two sides becomes a conflict copy rather than
being overwritten.

### Limits

- Only `.md` files sync. Images and other attachments don't yet.
- Hidden files and folders (names starting with `.`) are skipped on both sides.
- Very large repositories (where GitHub truncates the file listing) are
  refused, so missing files are never taken as deleted. The whole repository
  counts, not just the notes folder, so use a repository just for notes.
- The app isn't sandboxed. If you turn on App Sandbox, also tick
  **Outgoing Connections (Client)**.
