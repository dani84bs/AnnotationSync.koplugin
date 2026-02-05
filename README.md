# AnnotationSync.koplugin

> **Sync your KOReader annotations everywhere!**
>
> Never lose a highlight or note again—AnnotationSync keeps your reading life in sync across all your devices.

## 🚀 Features

- **Cloud sync for KOReader annotations** (highlights, notes, bookmarks)
- **Manual sync & remote backup** for peace of mind
- **Easy access from KOReader's main menu**
- **Configurable cloud server settings**
- **Smart merging:** resolves annotation conflicts by update time
- **Detects and marks deleted annotations**
- **Trash Bin & Restoration:** easily view and undelete accidentally removed notes
- **Supports multiple annotation formats & metadata**
- **Lightweight, minimal setup—just enable and configure!**

## 📦 Installation

1. Copy this folder to your KOReader `plugins` directory (make sure it is named `AnnotationSync.koplugin`)
2. Restart KOReader.
3. Enable AnnotationSync from the plugins menu.

## 🛠 Usage

- Open KOReader and activate AnnotationSync from the plugins menu:
  - Tools -> More tools -> Plugin management
- Choose the cloud storage source in Annotation Sync settings:
  - Tools -> Annotation Sync -> Settings
  - Add a cloud storage service, if necessary:
    - Add service -> +
    - Supported providers: Dropbox, FTP, WebDAV
  - Select the desired cloud storage service from the list
  - Restart KOReader as indicated after selection

- Sync your annotations at any time:
  - Use the menu: Tools -> Annotation Sync -> Manual Sync
  - Or bind the "Annotation Sync: Manual Sync" action to a gesture or keyboard shortcut
  - Or add the "Annotation Sync: Manual Sync" action to a profile action list

- Restore deleted annotations:
  - Use the menu: Tools -> Annotation Sync -> Show Deleted
  - Tap on any deleted item to restore it, or use "Restore All" to recover everything.
  - Restored items will be re-synced to the cloud on the next sync.

- Sync old annotations:
  - The plugin keeps track of the annotations you make without syncing (like when offline).
  - Use the "Annotation Sync: Sync All" button to mass upload them.

### 📦 DropBox setup

Setting up Dropbox on Koreader can be a little bit difficult. 
[This excellent post on mobileread forum](https://www.mobileread.com/forums/showthread.php?t=353670) explains the procedure in detail.

## Details

AnnotationSync stores its files directly in the selected cloud storage
directory, so you may want to create a new directory dedicated to AnnotationSync.
By using the default settings (i.e. "Use filename instead of hash" unchecked) the sync files are named according to a hash of the document being synced, so it
will look something like this:

```
.
..
330209864aecdf8cc63a16022f6a30f8.json
dda324e17e50f6c8c4c481ee4fcb1aa4.json
```

There is currently no other identifying information about the original document name stored in either the
filesystem or the contents of the files.

If you prefer to use the filename instead of an hash of the content just check the box under:
Tools -> AnnotationSync -> Settings -> Use filename instead of hash
By doing so the filename on every device should be the same.
This option should be chosen by users that change file metadata (e.g. with Calibre) otherwise the hash would change everytime you make any modification.

## 🧪 Running Tests

The project includes a comprehensive integration test suite. To run them, you need a KOReader development environment (`kodev`).
There are two ways for running them:
- Automated script
- Manual run

### Automated script

The script should take care of manually setting up the tests inside KOReader's base directory and run them.

```bash
./run_tests.sh <path_to_koreader>
```

### Manual run

#### 1. Setup

Test files must be symbolically linked into the KOReader core `spec/unit` directory:

```bash
cd /path/to/koreader
ln -s ../../plugins/AnnotationSync.koplugin/spec/unit/*.lua spec/unit/
```

#### 2. Execute Tests

Run all tests or a specific suite using `./kodev`:

```bash
# Run all AnnotationSync integration tests
./kodev test front sync_integration sync_pdf_integration sync_bookmark sync_mixed_offline sync_protection sync_trash error_handling

# Run a specific suite (e.g., PDF integration)
./kodev test front sync_pdf_integration
```

#### 3. Test Suites

- `sync_integration`: Core EPUB merging and conflict resolution.
- `sync_pdf_integration`: PDF-specific coordinate merging and drift tolerance.
- `sync_bookmark`: Bookmark (page-based) tracking and synchronization.
- `sync_mixed_offline`: "Sync All" behavior with mixed document types and offline handling.
- `sync_protection`: Safety checks to prevent accidental remote data loss.
- `sync_trash`: Verification of deleted item retrieval and restoration logic.
- `error_handling`: Network flakiness and malformed data scenarios.

## 🤝 Contributing

Pull requests, feature suggestions, and bug reports are very welcome! Open an issue or submit a PR.

## 📄 Known Issues

- ~~Can't synchronize pdf higlights due to their different data structure.~~ Fixed
- ~~Binding the "Annotation Sync: Manual Sync" action to a profile with "Auto-execute -> on book closing" will cause KOReader to crash.~~ Fixed

---

**AnnotationSync.koplugin**: Your reading notes, highlights, and bookmarks—always with you, always safe.

